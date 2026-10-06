# CLAUDE.md — Easy Spectrum

Emulador de ZX Spectrum en Flutter para Android y Windows (iOS preparado, sin probar).
Paquetes: `cl.easysoft.easyspectrum` (Free, con anuncios) y `cl.easysoft.easyspectrum.pro`
(Pro, sin anuncios) — ver "Ediciones". Repo: https://github.com/cmgonzalez/easy-spectrum
UI accesible (botones ≥64dp, fuente ≥18–20sp), estética Spectrum (negro + arcoíris).
Base de estructura: `C:\dev\easygbemu` (mismo patrón FFI + Ticker + flutter_soloud).

> **Leer también:** `C:\dev\CLAUDE.md` — instrucciones globales del workspace.

---

## Stack

| Capa | Tecnología |
|------|-----------|
| Core | **Clock Signal (CLK)**, Thomas Harte, MIT — submódulo `native/CLK` (shallow) |
| Bridge | C++20 `native/zx_bridge.{h,cpp}` → `libzx_bridge.so` vía dart:ffi |
| Audio | flutter_soloud, stream s16le estéreo 48 kHz |
| Ads | google_mobile_ads (IDs de prueba) — banner home + interstitial al salir |
| ABIs | arm64-v8a, x86_64 (emulador) |

Modelos: 16K, 48K, 128K, +2, +2A, +3, Timex TC2048 y TS2068 (ver sección propia) (+ ZX Spectrum Next solo para `.nex`, ver sección propia). Formatos: `.tap .tzx .csw .z80 .sna .szx .dsk .nex` (+ `.zip`).
ROMs en `assets/roms/` (48.rom, 128.rom, plus2.rom, plus3.rom = p2a41) — Amstrad permite
distribuirlas con emuladores. Se copian a `<appSupport>/roms` al primer arranque (el core las lee por ruta).

---

## Arquitectura nativa (lo no obvio)

- **CLK no trae salida por software**: entrega vídeo como *scans* de un CRT simulado
  (`Outputs::Display::ScanTarget`) pensado para OpenGL. `SoftScanTarget` en `zx_bridge.cpp`
  los rasteriza a un framebuffer RGBA **320×256** (256×192 + 32 px de borde):
  - `data_offset` de cada scan es relativo al último `begin_data()`.
  - Horizontal: se calibra con el primer scan de papel (≥64 muestras) → unidades/píxel y x del papel.
  - Vertical: se cuentan `EndHorizontalRetrace` desde `EndVerticalRetrace`; la primera línea con
    papel fija la fila 32.
  - Frame completo en `BeginVerticalRetrace` → copia a buffer frontal.
- **Fuentes de CLK**: solo el subconjunto listado en `native/CMakeLists.txt` (obtenido enlazando con
  `--no-undefined`). **No** añadir `Analyser/Static/StaticAnalyser.cpp`: arrastra todas las máquinas.
  Los medios se abren directamente (`ZXSpectrumTAP`, `TZX`, `CSW`, `CPCDSK`, `State::Z80/SNA/SZX::load`).
- **`android_prelude.h`** (forzado con `-include`): bionic declara `typedef unsigned int uint_t;`
  que choca con la plantilla `uint_t<N>` de CLK. Se incluye `<sys/types.h>` con el nombre renombrado.
- **Autocarga de cintas**: 128K/+2/+3 → `should_hold_enter` (Enter elige "Tape Loader").
  48K/16K → secuencia propia `J`, `SS+P`, `SS+P`, `Enter` con 0,12 s pulsada / 0,2 s suelta,
  empezando a los 2,5 s. **No usar el Typer de CLK** para esto: va a 1 tecla/frame y el
  debounce del ROM 48K se come la segunda comilla (queda `LOAD "` → error).
- Audio: el `Speaker` de CLK llama al delegate desde el hilo de su `AsyncTaskQueue`
  → ring buffer con mutex. `zx_run()` hace `run_for` + `flush_output(All)`.
- No hay save states: CLK no expone captura de estado del Spectrum (solo carga de snapshots).
- **SNA 128K**: CLK solo carga SNA de 48K (49179 bytes). `load_sna128()` en el bridge lee los de
  131103/147487 bytes (arma `Sinclair::ZXSpectrum::State` con los 8 bancos en orden y `last_7ffd`).
  Los `.sna` que empiezan con `MV - SNA` son de Amstrad CPC → error `cpc_snapshot`.
- **Floating bus exacto** (parches `floating-oob` / `floating-valor` sobre `Video.hpp`, 2026-10-03): el
  `get_floating_value()` de CLK devuelve `last_fetches_`, que solo se rellena al completar una columna del
  raster (y solo con buffer de píxeles): iba una columna atrasado y la última pareja de cada línea aparecía al
  principio de la siguiente. Los juegos que sincronizan por floating bus (aline, `C:\dev\super_gandalf`)
  enganchaban a veces una scanline tarde (multicolor parpadeando). Ahora se lee directo de la memoria de vídeo
  según `time_into_frame_`, con `zx_fb_lag` (half cycles, 0) en `zx_bridge.cpp`. Medido con PDP: los saltos de
  ±196 T desaparecen; queda una variación de 3-5 T en la salida de aline (sin causa confirmada) que no se ve.
  Sin probar en 48K/+2A/+3 ni con otros juegos de floating bus.
- **Parche a CLK sin tocar el submódulo**: `ZXSpectrum.cpp` se compila desde una copia que genera
  CMake (`ZXSpectrum_patched.cpp` en el dir de build). Bug upstream: al instalar un estado 128K no
  llama a `set_video_address()` → se ignoraba la pantalla sombra (banco 7) en .sna/.z80/.szx 128K.
  Segundo parche: `get_tape_is_playing()` = motor encendido **y** cinta sin terminar (ver turbo).
  Si CLK cambia ese código, el configure falla con "Parche ZXSpectrum.cpp '<nombre>': no se encontró el texto".
- **Discos +3 de doble cara / cargadores propios** (parches `disco-dos-caras` y `seek-*`, 2026-10-04): la
  unidad que crea `Machines/AmstradCPC/FDC.hpp` tenía 1 cabeza → +3DOS leía el ID de la cara 1, recibía H=0 y
  caía al cargador de cinta con los discos de 720K (80 pistas, 2 caras). Ahora 2 cabezas (`FDC_plus3.hpp` en el
  dir de build). Además el 8272 de CLK nunca apagaba los bits "unidad buscando" (0-3) del registro de estado
  principal: los cargadores que hablan directo con el FDC y esperan a que se apaguen se colgaban tras el
  RECALIBRATE (`i8272_patched.cpp`). Verificado con Flashback +3 (`flashback-l1.dsk`) en Windows headless;
  sin probar de nuevo un `.dsk` normal de 40 pistas / 1 cara. Sigue habiendo una sola unidad (A:).
- **Carga rápida = trap + turbo.** El trap de CLK solo intercepta `LD-BYTES` del ROM (0x056B):
  sirve para .tap, pero casi todos los .tzx traen cargadores propios (Ocean 0x11, Speedlock
  0x12/0x13…) que cargarían a velocidad real. `zx_run()` emula en turbo mientras la cinta gira:
  tramos de 20 ms hasta el 75% del tick (máx. 25 ms), tope ×50, **sin rasterizar** (`SoftScanTarget::set_drawing(false)`) en los tramos
  intermedios (rasterizar era el grueso del costo) y audio silenciado. CLK enciende el motor al
  detectar un bucle cerrado de lectura del puerto FE, lo que también ocurre en menús que leen el
  teclado: por eso el parche de "cinta terminada" y, además, una pulsación del usuario suspende
  el turbo hasta que el motor se detenga (multicargas). UI: ⏩ en la esquina inferior derecha de la imagen (`GameDisplay.turbo`, vía `zx_is_turbo`).
  **No desconectar el ScanTarget** (`set_scan_target(nullptr)`): deja de contar líneas y el
  primer frame tras reconectar sale corrido y recalibra mal → la imagen saltaba arriba/abajo.
  Solo se publican frames dibujados completos (de un retrazo vertical al siguiente).
  Medido en AVD x86: Cobra (.tzx Ocean) ~40 s en vez de ~3,5 min; Green Beret (Speedlock) al menú.
- Dart: ticks de hasta 100 ms se emulan completos (antes >100 ms se trataba como 20 ms → cámara
  lenta en teléfonos cargados); solo >0,5 s (pausa) se descarta.

## Gestor de cintas (doc/TAPE_MANAGER.md)

Lista de bloques, transporte (● ▶ ⏸ ■ ⏮ ⏭ ⏏), cinta nueva desde archivos y grabación de SAVE.
- **Posición**: parches CMake `cinta-bloque*` sobre copias de `ZXSpectrumTAP.cpp`/`TZX.cpp`
  (`*_patched.cpp` en el dir de build) avisan `zxtape::note_block(offset)` al empezar cada
  bloque (`native/zx_tape.h`). El índice sale de `scan_tap`/`scan_tzx` (`zx_bridge.cpp`), que
  numeran **igual que `lib/core/tape/tape_file.dart`**: si se toca uno, tocar el otro.
- **API**: `zx_tape_insert/eject/seek/info/set_paused/record/take_recorded`. Seek = recorte a
  `<roms>/.tape_seek{0,1}.*` + `insert_media`. Pausa también apaga el motor automático.
- **SAVE**: parche `cinta-grabar` (5º de `ZXSpectrum.cpp`): con la grabación activa, el fetch
  de 0x04C2 (SA-BYTES, ROM 48 BASIC) copia flag+datos+checksum y devuelve RET.
- Dart: `TapeController` (común), `features/tape/` (panel Windows, hoja + cassette Android,
  editor). Probar el núcleo sin Flutter: `tools/tapetest.cpp <roms> <cinta.tzx>`; compila con
  g++ de MSYS2 (`-include cstdint` etc. y `-Wl,--allow-multiple-definition` por el TLS de Log).

## Depurador PDP (Prisma Debug Protocol)

Sustituye a ZRCP de ZEsarUX para depurar juegos PRISMA: servidor TCP en el bridge (`native/zx_pdp.cpp`,
`zx_debug.h`, parche 4 de CMake). Protocolo, arquitectura y pendientes en `doc/PDP.md`.
Host headless `tools/pdp_host.py`, cliente `tools/pdp.py`, autotest `tools/pdp_selftest.py` (verificado
en Windows, 48K: breakpoints, step, next, mem, poke, reset). También depura la Next (`.nex`): parada entre
instrucciones en `NextMachine::cpu_step`, comandos extra `mmu`/`nextreg`/`mem page` — ver sección en `doc/PDP.md`;
autotest `tools/pdp_next_selftest.py` con el host `tools/nextpdp.cpp`.

## Probar el core sin Flutter

`tools/zxtest.cpp`: ejecutable que arranca la máquina, corre N segundos y vuelca `out.ppm`.
Compilar con el clang del NDK (target `x86_64-linux-android24` para el AVD, `aarch64` para el S24+),
push a `/data/local/tmp/zx/` junto con las ROMs, y ejecutar `./zxtest juego.tap <modelo> <segundos>`.
En Git Bash usar `MSYS_NO_PATHCONV=1` para que adb no reescriba las rutas `/data/...`.

## ZX Spectrum Next (solo `.nex`, sin NextZXOS)

Máquina **propia**, sin CLK, en `native/next/` (código nuestro: se puede mantener cerrado). Decisión de
licencias: CLK no emula la Next; ZEsarUX/JNEXT son GPL y CSpect es cerrado → se escribió desde la
documentación pública (wiki.specnext.dev) y **usando como referencia de consulta el driver BSD-3 de MAME**
(`src/mame/sinclair/next/`, copia local ignorada en `tools/_ref_mame/`; bajar con `gh api
repos/mamedev/mame/contents/src/mame/sinclair/next/<archivo> -H "Accept: application/vnd.github.raw"`).
**No copiar código de emuladores GPL**. Sin NextZXOS no hay problema con su licencia ("The Next License").
- `z80n.{h,cpp}`: Z80 + extensiones Z80N, T-states estándar sin contención. **Pasa `zexdoc` completo**
  (`tools/z80test.cpp`, CP/M mínimo; el .com está en github.com/anotherlin/z80emu/testfiles).
- `next_machine.{h,cpp}`: memoria (2 MB, MMU de 8 páginas de 8K, `$50-$57`), puertos, NextRegs, paletas,
  zxnDMA (`$6B` exacto, `$0B` Zilog N+1), interrupciones (pulso de 32 T o IM2 por hardware), 3×AY + DAC +
  beeper, cargador `.nex` (`load_nex`). Reloj en ticks de 28 MHz (1792 por línea, 312 líneas, 50 Hz).
- `next_video.cpp`: ULA (estándar, Timex 1/hi-color/hi-res, LoRes, ULANext), Layer 2 (256×192, 320×256,
  640×256), tilemap (40/80 col, modo texto 1 bpp), 128 sprites (ancla/relativos/4bpp/escala/rotación),
  Copper (granularidad de 8 px), orden de capas `$15`. Se dibuja línea a línea directo a 320×256 RGBA
  (mismo tamaño que el bridge de CLK).
- La línea `0` de la Next = primera línea de papel; INT de trama en la 248; coordenadas de sprites/tilemap
  = píxel del framebuffer (papel en 32,32).
- Al cargar un `.nex` se imita a NextZXOS: **`$4A` (color de reserva) = 0** (el core lo deja en `$E3`
  magenta; los juegos ponen `$14`=0 y esperan negro) y ROM 48K en `$0000-$3FFF`.
- Bridge: `ZX_MODEL_NEXT`; `zx_create` detecta la extensión `.nex` (ignora el modelo) y usa `ZxHandle::next`.
  Teclado/joystick (Kempston `$1F`)/audio/reset funcionan igual; cinta y Gigascreen no aplican.
- esxDOS (`next_esxdos.cpp`): `RST 8` (con la ROM en slot 0) se atiende en el host: F_OPEN/CLOSE/READ/WRITE/
  SEEK/FGETPOS/FSTAT/GETCWD/CHDIR y M_GETSETDRV, contra una carpeta (sin salir de ella, sin distinguir
  mayúsculas). El bridge usa `<juego>.files/` si existe, si no la carpeta del `.nex`. Al importar un `.zip`
  con un `.nex` (móvil: `GameLibrary.import`; escritorio: `_openPath`) se extraen los demás archivos a
  `<juego>.files/` (`GameLibrary.extractAssets`). Verificado con Fred In Space (assets/ en el zip).
- **Sprite tie (NR `$09` bit 4)**: puerto `$303B`/`$57` y NR `$34`/`$75-$79` comparten el número de sprite, y NR `$34` también fija el índice de patrón (bit 7 = mitad de 128 B). `sprite_tie_sync()`. Sin esto Aliens Neoplasma subía los patrones desalineados (cabezas dobles, sprites fantasma): usa NR `$34`+DMA a `$5B`. Teclas de ese juego: A/S/D/W mover, M/N/B/P fuego; en el menú, M para elegir.
- Mezcla de capas `$15`=110/111 (suma / resta 5/8 de Layer 2 sobre ULA+tilemap, sprites encima) hecha.
- **Pendiente**: teclas extendidas de la Next; ratón Kempston; CTC/UART/divMMC;
  ULA+ (puertos BF3B/FF3B); 60 Hz; miniatura sacada del `.nex`.
- Probar sin Flutter: `tools/nextest.cpp` (`clang++ -std=c++17 -O2 tools/nextest.cpp native/next/*.cpp`;
  `nextest juego.nex <s> [out.ppm]`; env `NX_REGS`, `NX_PIX=x,y`, `NX_DUMP=addr,n`, `NX_TRACE`,
  `NX_KEYS="t:0xFFBB:1;..."`, `NX_WAV=a.wav`). `tools/nexgen.py` genera un `.nex` de prueba propio (L2 + sprites + tilemap +
  Copper + DMA). Corre ×10-×15 tiempo real a 28 MHz en el PC. `.nex` reales de prueba (repos de GitHub:
  JohnGreening/maze, robgmoran/DougieDo, serdjukdev/ZxNextStudio-TechDemo) no se incluyen en el repo.

---

## Dart

```
lib/core/emulator/zx_bridge.dart   FFI (start/run/frame/keys/joystick/audio/tape)
lib/core/emulator/zx_types.dart    ZxModel, ZxKey (fila<<8|bit), ZxJoy, JoyMapping
lib/core/settings.dart             AppSettings (SharedPreferences)
lib/core/storage/game_library.dart juegos importados → <appDocs>/games (+ .zip)
lib/core/storage/game_thumbnail.dart miniaturas de "Mis juegos" (pantalla del Spectrum)
lib/core/storage/media_db.dart     base SQLite (sqflite) con todo lo de cada juego
lib/core/pad_config.dart           configuración del mando por juego
lib/features/game/                 game_screen (Ticker, reloj de pared), zx_keyboard, joystick_pad
```

### Base de datos de medios (`MediaDb`, `<appSupport>/media.db`)
Una fila por archivo de la biblioteca (clave = nombre del archivo; `<basic>` = sin medio):
`file_screen` (pantalla sacada del archivo; vacía = no trae; NULL = sin mirar), `net_screen`
(pantalla de ZXDB), `capture` (RGBA 256×192), `zxdb_status` (NULL sin consultar / 0 no está /
1 encontrado) + `zxdb_id, title, year, publisher, genre`, y `pad` (JSON de `PadConfig`).
Reemplazó las cachés en archivos (`thumbs/`, `info/`), que se borran al crear la base.
`GameLibrary.import` escribe a `.part` y renombra (la lista no debe leer el archivo a medias:
un archivo vacío tiene en ZXDB la huella de "Colours") y borra la fila si el contenido cambió;
`GameLibrary.delete` borra archivo + fila.

### Mando: botones de colores y configuración por juego
Botones de colores = `PadAction`: rojo configurar control (`pad_config_sheet.dart`), amarillo
Ajustes, verde teclado, azul volver a la lista. `PadConfig`: tipo (`JoyMapping`: Kempston,
Sinclair 1 6-7-8-9-0, Sinclair 2 1-2-3-4-5, Cursor, Teclado con teclas propias, QAOPM por
defecto) + botonera de 1-4 botones (rojo = fuego; amarillo, verde y azul = cualquier tecla).
La botonera es arte de `art/circles-optimized` pegado sobre el pozo del fuego por
`make_skins.py` → una piel por cantidad (`assets/skin/joystick_<n>.jpg`) y miniaturas
`buttons_<n>.png` para elegirla en el panel; el script imprime centro y radio de cada botón
(tabla `_clusters` en joystick_pad.dart). El toque dentro del anillo va al botón más cercano. 
Select / Start: 0-2 botones (cada uno con su tecla) sobre el LCD; arte `art/…19_44_24` (1) y
`…19_42_20` (2) → `assets/skin/select_<n>.png`, dibujado como calcomanía (`SkinView.decals`, sin
multiplicar las pieles); rectángulos en `_selects`. Con 0 no se dibuja nada. Se guarda
por juego en `MediaDb.pad`; sin configuración propia vale el "Control por defecto" de Ajustes
(`joy_type` en SharedPreferences; `joy_mapping` era el índice del formato antiguo).
LCD del mando: letrero en bucle (`_LcdPainter`, capa `SkinView.foreground` que se repinta con
un Ticker propio sin reconstruir el mando) con juego · año y editor · género · control · botones
extra · `<< ENTER | ESPACIO >>`; al pulsar una mitad se pinta en negativo. Vibración con
`lib/core/haptics.dart` (canal nativo, cruceta 10 ms suave, botones 22 ms firme).

### Miniaturas de juegos (`GameThumbnail`)
Pantalla de 6912 bytes ($4000) → imagen 256×192. Guardadas en `MediaDb`.
- `.tap`/`.tzx`: header Code en $4000 → seguro. Si no, candidatos (bloques ≥6912 con offsets
  1/0/2/3 —turbo 0x11 incluido—, 0x14 raw de 6912, pantalla partida 6144+768) filtrados por
  `_looksLikeScreen`: ≤64 atributos distintos, ≤25% FLASH y **coherencia vertical ≥0,45**
  (fila de píxeles ≈ la de abajo). Medido: pantallas reales 0,61–0,71; cifradas/comprimidas
  0,18–0,31. Muchas cintas protegidas (Speedlock, Hysteria, Cobra) cifran la pantalla: se descartan.
- `.sna` (48K y 128K), `.z80` (v1 RLE, v2/v3 por páginas), `.szx` (RAMP con zlib): desde la RAM,
  respetando la pantalla sombra (bit 3 de $7FFD → banco 7). `.szx` sin probar (no había muestras).
- Sin pantalla en el archivo (cifrada, `.dsk`, `.csw`): al **salir del juego** se guarda la
  pantalla del emulador (`saveCaptureIfMissing`, recorte de papel del framebuffer; se descartan
  pantallas lisas). Se espera antes de salir para que el inicio no cachee "sin imagen".
- Origen: lógica de easytape-app (`TapDecoder/TzxDecoder.extractLoadingScreen`), ampliada.

- Loop: cada tick de vsync se llama `zx_run(delta real)`; delta >0,1 s se descarta (pausa).
- Teclado: multitáctil con `Listener`; CAPS/SYM se fijan con un toque y se sueltan tras la siguiente tecla.
- Joystick: ver "Mando: botones de colores y configuración por juego".
- **Pieles** (`assets/skin/`, fuente en `art/` 11_32_04 teclado y 11_23_12 mando): `skin.dart`
  (`SkinView`) ajusta la imagen (contain), traduce toques a píxeles de la imagen y `SkinPainter`
  dibuja overlays en esas coordenadas. **Revisar el perfil de color de las imágenes nuevas**: la
  del teclado venía en HDR (ICC Rec.2020 PQ, píxel máx. 124): los visores la muestran viva, pero
  Flutter ignora el ICC y se veía apagada → se convierte a sRGB con `ImageCms.profileToProfile`
  al generar el JPG. La geometría está medida sobre la imagen (constantes en
  `zx_keyboard.dart` / `joystick_pad.dart`): **si se cambia la imagen hay que re-medir**.
  - Teclado: 4 bandas de fila × 10 teclas; el toque va a la tecla de centro más cercano de su
    fila (los huecos cuentan). Verificado tecleando `PRINT 7*6` → 42 en 48 BASIC.
  - Recortes: `SkinImage(..., origin:)` = esquina del asset en la imagen original; la geometría
    sigue en coordenadas de la original. **Los assets los genera `python tools/make_skins.py`**
    desde `art/`: teclado sin cabecera + franja metálica inferior reflejada arriba (origen (0,268));
    mando sin el relleno interior y con un **marco redibujado** con el perfil de relieve real de
    cada lado (origen (121,146), controles ×1,10). Pegar trozos del marco original dejaba
    escalones y muescas en las curvas de las esquinas.
  - **Teclado compacto** (móvil): `assets/skin/keyboard_keys.jpg` = recorte de `keyboard.jpg` (x 24..1512,
    y 180..899, sin cabecera ni márgenes; `_skinCompact` en `zx_keyboard.dart`, origen (24,240)). Se hizo con
    PIL a mano (no está en `make_skins.py`): si se regenera `keyboard.jpg`, repetir el recorte. En vertical se
    estira ×1,2 en alto (`ConsoleView.controlsAspect`); Windows sigue usando la foto completa.
  - Mando: cruceta (ángulo, 8 dir., se puede deslizar), botón redondo = FUEGO, botones de
    colores = teclas 1-4, LCD partido = ENTER | ESPACIO (rótulos pintados encima).
  - Distribución actual: ver "Consola portátil" más abajo.

## Fichas de ZXDB (ajuste "Buscar datos de los juegos en internet", activado por defecto)

`lib/core/storage/game_info.dart` (`GameInfoService`): MD5 del archivo → `GET https://api.zxinfo.dk/v3/filecheck/<md5>`
(404 = no está) → `GET /v3/games/<id>?mode=compact` → título, año, editor, género y `screens[]`.
La pantalla de carga (`scrUrl`, .scr de 6912 bytes) se baja de `https://zxinfo.dk/media<scrUrl>` y va a
`MediaDb.net_screen`. Prioridad de miniatura: pantalla del archivo > ZXDB > captura del emulador.
- Solo por hash (volcados de WOS/TOSEC/Spectrum Computing). **No buscar por nombre**: "Cobra"
  devuelve primero el de ZX81. `api.zxinfo.dk` redirige (301) a `internal.zxinfo.dk`.
- Guardado en `MediaDb` (`zxdb_status` 0 = no está en ZXDB). Archivos < 256 bytes no se consultan. Errores de red no se cachean (se reintenta
  en la próxima sesión). Sin cuenta ni clave; User-Agent propio.
- Miniatura automática sin red: `GameScreen._checkCapture` captura al terminar la primera carga
  (cinta parada 2 s; sin cinta, a los 15 s). Si la pantalla final es pobre (créditos en 2 colores)
  usa la última pantalla con color vista durante la carga (= pantalla de carga).

## Abrir archivos desde otras apps

`AndroidManifest.xml` declara `VIEW` (por tipo MIME: `application/octet-stream`, zip… y por
`pathPattern` de extensión cuando la URI la trae) y `SEND` (`application/*`). Casi todas las apps
entregan `content://` sin extensión y con tipo genérico: por eso la app aparece también en
"Abrir con" de otros archivos desconocidos (si no es de Spectrum, sale el error de formato).
- `MainActivity.kt`: canal `cl.easysoft.easyspectrum/open`; Dart pide `initial` al arrancar y
  recibe `open` con la app abierta (`onNewIntent`, `singleTop`). Lee nombre (`DISPLAY_NAME`) y
  bytes en un hilo; el intent se marca consumido (action → MAIN).
- `lib/core/storage/incoming_files.dart`: si el nombre perdió la extensión (WhatsApp/Telegram)
  se deduce del contenido (`ZXTape!`, `PK`, `ZXST`, tamaños de SNA).
- `HomeScreen._openIncoming`: vuelve al inicio, espera `GameScreen.whenClosed()` (el dispose de
  la pantalla anterior libera la máquina nativa, que es única) e importa + juega.
- Probar en el AVD: `adb shell am start -a android.intent.action.VIEW -t application/zip
  --grant-read-uri-permission -d content://media/external/downloads/<id> -n cl.easysoft.easyspectrum/.MainActivity`
  (`<id>` con `content query --uri content://media/external/downloads`).

## Consola portátil (pantalla del juego)

`ConsoleView` (console_view.dart) ocupa todo bajo la barra superior: cuerpo con `body_top.jpg`,
`body_mid.jpg` repetido y `body_bottom.jpg` (mismos cantos que el arte del mando) y, de arriba
abajo: LED POWER + rejilla, la pantalla del juego en un vidrio (ancho útil, tope 40% del alto),
el LCD (`LcdPanel`: letrero + mitades ENTER | ESPACIO), la fila de `ActionButtons` (los 4 de
colores, **misma posición con mando y teclado**; con teclado el verde lleva el ícono de mando) y
el área de controles. La pantalla mide lo mismo en ambos modos.
- Mando (`JoystickPad`): piezas colocadas por código (`_Layout`), nunca deformadas: `dpad.png`
  a la izquierda, `cluster_<n>.png` a la derecha (botones en fracciones del lado, tabla
  `_clusters`), `select_<n>.png` centrado debajo; el alto sobrante se reparte en los huecos.
  Arcoíris dibujado (`_RainbowPainter`) con el ángulo y ancho del teclado (25 px por 60 de alto).
- Teclado: su arte con cabecera, sin estirar (contain), centrado en el área; `SkinView` sin fondo.
- Piezas generadas por `make_skins.py` (`controls()`, `body()`, `select_buttons()`); el mando ya
  no es una sola imagen (se borraron `joystick_<n>.jpg`).
Salto: `PadConfig.jump` = botón de color (1-3) que envía "arriba"; la cruceta deja de enviarlo.

## Gigascreen (Ajustes › Pantalla, desactivado por defecto)

`SoftScanTarget` publica cada frame mezclado con el anterior (`zx_set_gigascreen`, `AppSettings.gigascreen`).
Mezcla en luz lineal (gamma 2,2 con tablas), no promedio sRGB: negro + blanco (215) = 157, como el
parpadeo en un CRT. Es solo visual; se combina con cualquier modo de video. Verificado en Windows con
un SNA 128K que alterna pantalla normal (negra) y sombra (blanca) en cada frame: sin Gigascreen
0/215 alternando, con Gigascreen 157 fijo. Escritorio: menú Pantalla › Gigascreen.
Autotest: `python tools/gigascreen_test.py` (genera un SNA 128K que conmuta el bit 3 de `$7FFD` en cada
interrupción; comprueba con la DLL de Windows atributos distintos, solo píxeles distintos y zona idéntica).

## Interlace hi-res (Ajustes › Pantalla, desactivado por defecto)

Modo "LCD" de Velesoft: los programas que alternan dos pantallas a 50 Hz (vía bit D3 de
`$7FFD`, banco 5 ↔ banco 7) se muestran como **256×384 de alta resolución** intercalando los
dos frames como campos par/impar — igual que el des-entrelazado de un TV LCD o del scandoubler
ZX-HD/VGA-JOY con la señal real. Excluyente con Gigascreen (que mezcla los dos frames en vez de
intercalarlos; activar uno apaga el otro, en `settings.dart` y en los toggles).
- Nativo (`SoftScanTarget`, `zx_bridge.cpp`): con `interlace_`, en cada `BeginVerticalRetrace`
  limpio el frame va a las filas `2r+field_` de un buffer de doble alto `front_hr_` (320×512) y
  `field_` conmuta 0/1. `front_` sigue guardando el campo suelto (320×256) → capturas/miniaturas
  no cambian. `field_` solo conmuta en frames dibujados, así el emparejamiento no se desfasa en los
  saltos de turbo.
- **Paridad de campo** = pantalla mostrada (bit 3 de `$7FFD`, leído a mitad de frame por
  `zxdbg::g.t.paging`): normal (banco 5) → filas pares, sombra (banco 7) → impares. Con la paridad
  ligada al frame en que se activaba el modo, la mitad de las veces los campos salían cruzados
  (texto y diagonales dentados). Si el programa no alterna con `$7FFD` (48K, o cambia la pantalla
  copiando memoria) se alterna sola y la paridad queda al azar.
- Verificación sin Flutter: `C:\dev\entrelazado\mktestcard.py` genera una carta de ajuste `.z80`
  (IM2 + HALT alternando `$7FFD`); cargada con ctypes sobre `zx_bridge.dll`, `zx_get_framebuffer_hr`
  coincide píxel a píxel con la referencia. Al generar `.z80` propios: cabecera v3 (54) con hardware
  **4** = 128K (el 3 es 48K+MGT), páginas siempre comprimidas (CLK no salta bien las de `0xFFFF`).
- **Mezcla de color** (`front_hr()`): al publicar, cada línea se funde con sus vecinas (del otro
  campo) con un filtro vertical 1-2-1 en luz lineal, como hace un LCD. Las imágenes `.lce` de
  Velesoft (LCDgfx50) cuentan con eso para sus colores extra: solo intercalando se veían rayas de
  dos colores. Costo: una rejilla de 1 px par/impar se ve gris uniforme (igual que en el LCD).
  `C:\dev\entrelazado\lce2z80.py` empaqueta un `.lce` en un `.z80` que alterna las pantallas.
- **Sincronía de campos:** si el campo que llega cambió en 64 filas o más (`SyncRows`; con 16 un
  sprite que se redibuja en cada campo se tomaba por scroll y dejaba 2 frames desfasados) respecto de lo que se
  muestra (`changed_rows`), se retiene un frame (`pending_buf_`) y se publica junto con su pareja.
  Un scroll entrelazado (dos pantallas que se actualizan en frames consecutivos) ya no muestra
  el frame de imagen doble de cada paso: la demo `C:/dev/entrelazado/pinball/p256-scroll.z80` da
  420 de 420 frames idénticos a la referencia (antes 340). Costo: un frame de latencia cuando hay
  cambios, y un programa que no alterna pantallas se actualiza a 25 fps en este modo.
- API FFI nueva: `zx_set_interlace`, `zx_get_framebuffer_hr` (320×512), `zx_fb_height` (256 o 512).
  No aplica a la Next (`zx_fb_height` devuelve 256). Símbolos exportados por `WINDOWS_EXPORT_ALL_SYMBOLS`.
- Dart: `ZxBridge.frame()` consulta `zx_fb_height` y decodifica 320×256 o 320×512 (`zxFbHeightHr`).
  `GameDisplay._FramePainter` deriva el borde vertical del alto real (×2 en HR); la proporción
  física (`aspectFor`) no cambia porque cada scanline mostrada mide la mitad.
- Persistencia `interlace` en `AppSettings` (global + por juego, igual que gigascreen).
- **`--interlace` por linea de comandos** (2026-10-05, lo pasa PRISMA con el motor
  `GFX_INFERNO_INTERLACE`): `_forceInterlace` en `DesktopScreen`, solo para la sesion (no
  se guarda en `AppSettings`); tocar Gigascreen/Interlace HR en el menu lo suelta, y cada
  archivo reenviado a la instancia abierta trae (o no) su propio `--interlace`.

## Timex TC2048 / TS2068 y ULAplus extendido (2026-10-06)

Pedido por PRISMA (`C:\prisma\doc_ia\INFERNO_TIMEX_PLAN.md`, §7: motor `GFX_INFERNO_TIMEX`, hi-color 8x1).
- **Modelos**: `ZX_MODEL_TC2048` = 7, `ZX_MODEL_TS2068` = 8 (el 6 es la Next). En CLK se agregan **al final** del enum
  `Target::Model` con una copia de `Target.hpp` en `<build>/clk_over/` (directorio de includes antepuesto; todos la
  incluyen como `"Analyser/Static/ZXSpectrum/Target.hpp"`). El bridge traduce (`clk_model` / `zx_model_of`).
  Dart: `ZxModel.tc2048/ts2068` con `id` (el índice del enum es lo que se guarda en ajustes). `--model tc2048|ts2068`.
- **ROMs**: `assets/roms/tc2048.rom` (16K) y `ts2068.rom` (24K = casa 16K + EXROM 8K), copiadas del ZEsarUX de
  PRISMA (la de 2068 es idéntica a `tc2068-0/1.rom` de Fuse). ⚠ **Licencia**: el permiso de Amstrad no cubre las
  ROM de Timex; revisar antes de publicar en Play Store. El TC2048 pide la ROM "48K" de CLK y el TS2068 la "+3"
  (64K, para que no la recorte a 16K): el fetcher del bridge les da la suya.
- **Máquina** (`clk_patches/timex_machine.inc`, `timex_out.inc`, `timex_in.inc`, parches `timex-*` de
  `ZXSpectrum.cpp`): para el resto del código son 48K (`base_model`). **Al final del parcheo, un `REGEX REPLACE`
  cambia toda comparación `model <op> Model::X` por `base_model`**: en código inyectado escribir `Model::X == model`.
  `banks_` pasó a **8 chunks de 8K** en todos los modelos (`set_memory` llena dos; `banks_[address >> 13]`).
  - `$FF` (los dos, byte bajo completo): b0-5 modo de vídeo → `Video::set_timex_mode`, b6 corta la interrupción,
    b7 elige EXROM/DOCK. Se lee de vuelta.
  - TS2068: `$F4` MMU horizontal (`timex_overlay()` al final de `update_memory_map`: EXROM espejado o DOCK vacío
    = `$FF`, escrituras a `scratch_`), AY en `$F5`/`$F6` (reloj CPU/2), joysticks por el registro 14 (A8 = 1,
    A9 = 2, activos a 0), `$FE` decodificado completo (`$F4/$F6` también tienen A0 = 0), 3,528 MHz, sin trap de
    LD-BYTES ni de SA-BYTES (su ROM es otra: carga a velocidad real + turbo).
  - Escrituras en `$6000-$7AFF` vacían el vídeo solo con un modo Timex activo (`video_write_limit`).
- **Vídeo** (`ulaplus_private.inc`, `output_column()` reemplaza el bucle de columnas de `Video.hpp`): modo 1 =
  segunda pantalla `$6000`; 2 = hi-color (atributo = dirección del píxel `| $2000`); 4/6 = hi-res 512 (tinta = b3-5,
  papel y borde = complemento, con BRIGHT; con ULAplus CLUT 3). **Hi-res fase 1**: 512 → 256 muestras (pares
  iguales = ese color, distintos = la media); falta un framebuffer de 640.
  Timings (libspectrum): `Timing::TC2048` 48K con el papel 15 ciclos antes; `Timing::TS2068` NTSC 224×262,
  interrupción 9169 ciclos antes del papel, CRT `NTSC60` (60 fps; tarda ~1 s en fijar la vertical).
- **Snapshots `.z80`**: hardware 14 = TC2048, 15/128 = TS2068; byte 35 = `$F4` (en `last_7ffd`), 36 = `$FF` (en
  `last_1ffd`). `zx_save_snapshot` los escribe (v3; el TS2068 con AY). `.sna` = 48K (pierde `$FF`); `.szx` sin Timex.
- **ULAplus opcional** (`zx_set_ulaplus`, `AppSettings.ulaplus`, global): 0 apagado (BF3B/FF3B no responden),
  1 paleta, 2 **extendido** (defecto): el subgrupo del registro de modo (`BF3B` = `$40 | modo`) replica los modos de
  `$FF` en cualquier modelo. Escala de grises (bit 1 del modo) implementada. Móvil: Ajustes › Pantalla (solo en los
  ajustes generales); Windows: Máquina › ULAplus.
- PDP: `hello` trae `model` (`tc2048`, `ts2068`…), `paging` agrega `timex_ff`, `timex_f4`, `screen_mode`.
- Autotest: `python tools/timex_test.py [--ppm carpeta]` (arranque de las dos ROM, modos 0/1/2/6 + borde hi-res,
  ULAplus extendido con el ajuste en 2/1/0, ida y vuelta de `.z80` TC2048, EXROM por la MMU, AY y joystick del TS2068).
- Pendiente: hi-res a 640 px, `.szx` (`SCLD`), cartuchos DOCK, contención de I/O propia del SCLD, TC2068 (PAL) como
  modelo aparte, verificar con juegos/demos reales de Timex.

## ULAplus (Android y Windows; desactivable, ver Timex)

CLK no lo trae: va por parches generados en CMake (mismo mecanismo que `ZXSpectrum_patched.cpp`,
funciones `clk_patch` / `clk_patch_block`). Si CLK cambia upstream, el configure falla con el nombre
del parche.
- `ZXSpectrum.cpp`: puertos `0xBF3B` (registro) y `0xFF3B` (dato, lectura y escritura, decodificación
  completa: no chocan con FE/7FFD/FFFD/BFFD/1FFD/Kempston) y `soft_reset` apaga el modo ULAplus.
- `Video.hpp`: se genera una copia en el dir de build (con `State.hpp` copiado al lado, para que su
  `#include "Video.hpp"` tome la parcheada). Salida **Red8Green8Blue8** (antes Red2Green2Blue2: la
  paleta ULAplus es GRB 3-3-2); tinta/papel/borde por `ink_colour`/`paper_colour`/`border_rgb`.
  Código nuevo en `native/clk_patches/ulaplus_{public,private}.inc`. Con modo activo: CLUT =
  FLASH*2+BRIGHT (tintas 0-7, papeles 8-15), FLASH no parpadea, borde = papeles de la CLUT 0. El color
  se resuelve al leer cada par de bytes (vale para cambios de paleta a mitad de línea).
- Los 16 colores normales quedan con los niveles de siempre (0xD7 / 0xFF).
- Verificado con un SNA 48K propio: paleta 8 = rojo, 24 = verde, modo on, lectura de FF3B → borde y
  tercio superior (255,0,0), resto (0,255,0). Pendiente: bloque `PLTT` de los `.szx` (CLK lo ignora).

## Modos de video (`lib/core/video_mode.dart`)

Nítido (por defecto), Suave (bilineal), Bordes redondeados (ClipRRect), Monitor y TV CRT. Se eligen
en el menú ⋮ del juego (se aplican al momento) o en Ajustes › Pantalla; `video_mode` en
SharedPreferences. Monitor y TV usan `shaders/crt.frag` (técnica del CRT de Timothy Lottes, dominio
público, reescrita): curvatura, haz gaussiano por línea con ancho según brillo, máscara RGB en px
físicos (`uDpr`), resplandor, viñeta y esquinas redondeadas, en espacio lineal (gamma 2). El
sampler va con `FilterQuality.none` y el filtrado lo hace el shader. Orden de uniforms = orden de
`setFloat` en `game_display.dart`: si se agrega uno, actualizar ambos.

## Idiomas

`gen-l10n` con ARB en `lib/l10n/`: **es** (plantilla), en, ru, it, pt. Los `app_localizations*.dart`
se generan al compilar (están en `.gitignore`). Acceso con `context.l10n` (`lib/core/l10n.dart`).
El inglés es el idioma de reserva para locales no soportados.
- Añadir un texto: agregarlo a los 5 ARB (con `@clave`/placeholders solo en `app_es.arb`) y `flutter gen-l10n`.
- `zx_last_error()` devuelve códigos (`missing_roms`, `bad_snapshot`…) que traduce `zxErrorText()`.
- Probar un idioma en el emulador sin cambiar el sistema:
  `adb shell cmd locale set-app-locales cl.easysoft.easyspectrum --locales ru` (o `...easyspectrum.pro`)

## Ediciones Free / Pro (flavors)

Un solo código y dos apps: `productFlavors` en `android/app/build.gradle.kts` (dimensión `edicion`).

| | Free | Pro |
|---|---|---|
| applicationId | `cl.easysoft.easyspectrum` | `cl.easysoft.easyspectrum.pro` (`applicationIdSuffix`) |
| Nombre | Easy Spectrum | Easy Spectrum Pro (`resValue app_name`) |
| Anuncios | banner + interstitial | ninguno |
| Ícono | `android/app/src/main/res` (config en `pubspec.yaml`) | `android/app/src/pro/res` (`flutter_launcher_icons-pro.yaml`) |

**Íconos**: fuente en `art/` (ilustraciones con fondo completo; `10_50_38` Free, `10_50_51` Pro).
Adaptativo en dos capas generadas con Python: `app_icon[_pro]_bg.png` = la imagen desenfocada
(el degradado sigue hasta el borde de la máscara) y `app_icon[_pro]_fg.png` = la ilustración a
680/1024 con bordes difuminados; `adaptive_icon_foreground_inset: 0`. Legacy y Play Store
(`icon-app_play_512[_pro].png`) = imagen completa. **Gotcha**: si existe
`flutter_launcher_icons-pro.yaml`, `dart run flutter_launcher_icons` (incluso con `-f pubspec.yaml`)
solo procesa flavors → para la Free apartar temporalmente ese yaml.

- El `namespace` (paquete Kotlin) es el mismo en ambas: `MainActivity` no se mueve.
- Dart: `Edition.isPro` (`lib/core/edition.dart`) = `appFlavor == 'pro'`, constante de compilación.
  `AdManager` es no-op en la Pro (no inicializa AdMob; `createBanner` devuelve null).
- `android/app/src/pro/AndroidManifest.xml` quita con `tools:node="remove"`: `MobileAdsInitProvider`
  (**sin App ID tumba la app al arrancar**), el meta-data APPLICATION_ID, `AD_ID`, los tres
  `ACCESS_ADSERVICES_*` y la property `AD_SERVICES_CONFIG` que agrega el SDK. Si se actualiza
  google_mobile_ads, revisar con `aapt dump permissions app-pro-release.apk`.
- Cada edición tiene sus propios datos en el teléfono (biblioteca y ajustes no se comparten).
- `flutter build` **exige `--flavor free|pro`**.

## Windows (escritorio)

Mismo proyecto, otra interfaz: en escritorio `main.dart` abre `DesktopApp`
(`lib/features/desktop/`) en vez de la biblioteca y la consola táctil. Ventana con solo la salida
del Spectrum (`GameDisplay`, mismos modos de video y shader CRT) y barra de menús **nativa Win32**: Archivo (abrir,
recargar, recientes, BASIC), Máquina (modelo, reset, pausa, velocidad, carga rápida, cinta),
Pantalla (modo, tamaño ×1-×4, pantalla completa), Joystick, Ayuda. Sin anuncios ni biblioteca:
los archivos se abren en su sitio (`.zip` → temporal); arrastrar y soltar (`desktop_drop`), ventana
con `window_manager`, audio con la misma `ZxAudio` que Android.
- **Menú nativo** (no el `MenuBar` de Flutter, que no se comporta como los de Windows):
  `windows/runner/native_menu.cpp` arma un HMENU con lo que manda Dart por el canal
  `cl.easysoft.easyspectrum/menu` (`native_menu.dart`: `MenuEntry`, `NativeMenuBar`). Dart describe
  la barra entera en cada build y solo se reenvía si cambió; un cambio con un menú abierto se aplica
  al cerrarlo. `WM_COMMAND` → `select(id)`. Alt solo no activa la barra (es el fuego del joystick);
  Alt + letra sí. En pantalla completa se quita con `setVisible(false)`.
  **Colores Spectrum** (owner-draw): fondo negro, texto blanco, opción marcada en cian como el menú
  del 128K y arcoíris a la derecha de la barra (opción `MFT_RIGHTJUSTIFY` deshabilitada). Owner-draw
  obliga a: letra de Alt por `WM_MENUCHAR`, flecha de submenú propia (+ `ExcludeClipRect` para que
  Windows no pinte la suya), tapar la línea blanca bajo la barra en `WM_NCPAINT`/`WM_NCACTIVATE`, y
  `SetPreferredAppMode(ForceDark)` (uxtheme, ordinal 135, no documentado) para bordes oscuros.
  Barra de título negra con texto blanco siempre (`UpdateTheme` en `win32_window.cpp`, Windows 11).
- **Instancia única** (`windows/runner/single_instance.cpp`): mutex `Local\EasySpectrum.SingleInstance`;
  si ya hay una ventana (marcada con la propiedad `EasySpectrum.MainWindow`), la nueva instancia le
  manda sus argumentos por `WM_COPYDATA` (rutas ya absolutas), la trae al frente y sale. El runner
  los pasa a Dart por el canal `cl.easysoft.easyspectrum/open_args` → `_onOpenArgs`.
- **Instalador** (`installer/easy_spectrum.iss`, Inno Setup 6 — se usa el de `C:\prisma\bin\Inno Setup 6`):
  `bash build-app.sh installer` → `EasySpectrum-Setup-<ver>-<code>.exe`. Por usuario sin UAC (con
  opción "todos los usuarios"; registro en HKA), runtime VC++ copiado junto al .exe, idiomas
  es/en/pt/it/ru. Tipos: siempre en "Abrir con" (.tap .tzx .z80 .sna .szx .dsk .csw y .zip); la tarea
  "associate" (marcada) lo hace predeterminado salvo .zip. Si el usuario ya eligió otro programa con
  "usar siempre" (UserChoice), Windows no deja que un instalador lo cambie: se elige en "Abrir con".
  Windows 11 solo muestra en "Abrir con" (y solo usa como predeterminado) los programas que ya
  "reconoció" para la extensión: valor `<ProgId>_<ext>` / `Applications\<exe>_<ext>` en
  `HKCU\...\Explorer\ApplicationAssociationToasts`. El instalador los escribe; sin ellos la app no salía.
  También registra la app en `RegisteredApplications` (Capabilities en `Software\EasySoft\EasySpectrum`,
  sin .zip) y ofrece al final abrir `ms-settings:defaultapps?registeredApp{User|Machine}=EasySpectrum`;
  lo mismo hace Archivo › Establecer como predeterminado (runner: `openDefaultApps` por el canal
  `open_args`). Pendiente verificar que Configuración abra la página de la app y no la general.
  Verificado: instalación silenciosa, arranque desde la copia instalada y desinstalación sin restos.
- **Línea de comandos** (para PRISMA u otras herramientas):
  `EasySpectrum.exe juego.tap --model 48k|128k|+2|+2a|+3|16k`. Recargar (F4) vuelve a leer el
  archivo del disco: recompilar el .tap y F4.
- Teclado (`pc_keyboard.dart`): por posición; Shift = CAPS, Ctrl = SYM, signos por carácter con SYM
  (soltando CAPS), flechas + Alt/Tab = joystick elegido (o cursores). Cada tecla del PC recuerda lo
  que pulsó y la matriz se recalcula como unión → no quedan teclas pegadas. Teclas F al estilo Fuse:
  F1 mapa de teclas, F2 guardar snapshot, F3 abrir, F4 recargar, F5 reset, F6 gestor de cintas, F7 insertar
  cinta, F8 play/stop (Shift+F8 rebobinar), Pause pausa/reanudar, F9 soltar ratón, F11 pantalla completa,
  F12 copiar pantalla. Por eso los atajos van en teclas F: Ctrl es SYM.
- **Guardar snapshot** (F2, Archivo › Guardar snapshot, botón de la barra): `zx_save_snapshot` escribe
  `.z80` o `.sna` según la extensión; la emulación se pausa con el diálogo abierto. El estado se toma con
  la CPU detenida al inicio de una instrucción por el núcleo PDP (`capture_state` en `zx_bridge.cpp`;
  si el depurador ya la tenía parada, usa esa parada). Borde y T-states por `Video::State` (parche
  `tiempo-const`: su constructor no compilaba), registros del AY por `clk_patches/snapshot_access.h`
  (especialización de `GI::AY38910::State::apply<>`, amiga del AY). `.z80`: v2 (23 bytes) para 128K,
  porque en la v3 el modo 3 es 48K+M.G.T.; v3 (55 bytes, con `$1FFD`) para 16K/48K/+2/+2A/+3. `.sna` no
  guarda el modelo: uno de +2/+2A/+3 se reabre como 128K. Parches al lector `.z80` de CLK
  (`Z80_patched.cpp`): modos v3 4/5/6 = 128K (rechazaba los `.z80` 128K de Fuse) y color del borde
  (no se leía). Autotest: `python tools/snapshot_test.py` (ida y vuelta en los 6 modelos + contenido
  del `.z80` con pantalla sombra).
- **Core**: `windows/CMakeLists.txt` compila `native/` como proyecto externo con **clang-cl**
  (toolset `ClangCL`, siempre Release): MSVC no acepta las extensiones de GCC/Clang de CLK.
  zlib se baja con FetchContent. `windows_prelude.h` (/FI) define `ssize_t`.
- **Pila de 16 MB** (`/STACK` en `windows/runner/CMakeLists.txt`): con el 1 MB de Windows, crear la
  máquina desbordaba la pila (0xC00000FD en zx_bridge.dll).
- Requisitos: Visual Studio 2022 (Build Tools) con "Desarrollo para el escritorio con C++" +
  "Clang para Windows" (`VC.Llvm.Clang` y `VC.Llvm.ClangToolset`). Instalar componentes con
  `setup.exe modify ... --passive` exige consola elevada (si no, sale con 5007).
- `bash build-app.sh windows` → `build/windows/x64/runner/Release/EasySpectrum.exe` y
  `EasySpectrum-win-<ver>-<code>.zip` en la raíz. Primera compilación ~5 min.
- **Actualizar la instalación local rápido** (sin instalador): tras `bash build-app.sh windows`, cerrar la app y
  copiar `build\windowsd
unner\Release\*` sobre `%LOCALAPPDATA%\Programs\Easy Spectrum`
  (`Get-Process EasySpectrum | Stop-Process -Force; Copy-Item ... -Recurse -Force`). Solo cambian binarios:
  asociaciones y registro del instalador quedan intactos.
- Captura de la ventana para verificar: PrintWindow desde un proceso DPI-aware
  (`SetProcessDPIAware`), si no sale recortada con escalado 150%.

## Build

```bash
bash build-app.sh                  # APK release de las dos → EasySpectrum[Pro]-<ver>-<code>.apk
bash build-app.sh aab              # AAB de las dos (Play Store)
bash build-app.sh release pro      # solo una edición
bash build-app.sh release all push # + commit + push
bash build-app.sh windows          # EasySpectrum.exe (+ zip)
bash build-app.sh installer        # instalador Inno Setup
```
Equivale a `flutter build apk --release --flavor free` (o `pro`).
El versionCode está en `pubspec.yaml` y en `android/app/build.gradle.kts`: subir los dos.
Firma release: `android/key.properties` (no va al repo). Primera compilación nativa ~5 min (CLK × 2 ABIs).

## Estado

- [x] Core CLK compilando en Android (arm64/x86_64), 50 fps, audio 48 kHz
- [x] Carga de cinta verificada en 48K y +2 (Max Stone Dos, .tap)
- [x] UI: biblioteca, teclado ZX, joystick, ajustes, acerca de
- [x] APK release verificado en AVD (BASIC 128K, carga .tap, teclado, juego jugable)
- [ ] Probar en SM S926B (audio real)
- [x] Guardar snapshot .z80/.sna en Windows (F2). Falta en Android y el estado de cinta/disco
- [x] Ediciones Free/Pro con flavors (verificado en AVD: Pro sin anuncios ni permisos publicitarios)
- [ ] IDs AdMob reales (solo Free) / política de privacidad `www.easysoft.cl/easy-spectrum/privacy.html`
- [x] Localización es/en/ru/it/pt
- [x] SNA de 128K (cargador propio) + fix de pantalla sombra en snapshots 128K (verificado con SNA sintéticos)
- [ ] Un juego que falla al cargar queda igual en "Mis juegos" (¿borrarlo o marcarlo?)
- [x] Timex TC2048 / TS2068 + ULAplus extendido (núcleo verificado con `tools/timex_test.py`; falta probar juegos reales y la app)
