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

Modelos: 16K, 48K, 128K, +2, +2A, +3. Formatos: `.tap .tzx .csw .z80 .sna .szx .dsk` (+ `.zip`).
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
- **Parche a CLK sin tocar el submódulo**: `ZXSpectrum.cpp` se compila desde una copia que genera
  CMake (`ZXSpectrum_patched.cpp` en el dir de build). Bug upstream: al instalar un estado 128K no
  llama a `set_video_address()` → se ignoraba la pantalla sombra (banco 7) en .sna/.z80/.szx 128K.
  Segundo parche: `get_tape_is_playing()` = motor encendido **y** cinta sin terminar (ver turbo).
  Si CLK cambia ese código, el configure falla con "Parche ZXSpectrum.cpp '<nombre>': no se encontró el texto".
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

## Probar el core sin Flutter

`tools/zxtest.cpp`: ejecutable que arranca la máquina, corre N segundos y vuelca `out.ppm`.
Compilar con el clang del NDK (target `x86_64-linux-android24` para el AVD, `aarch64` para el S24+),
push a `/data/local/tmp/zx/` junto con las ROMs, y ejecutar `./zxtest juego.tap <modelo> <segundos>`.
En Git Bash usar `MSYS_NO_PATHCONV=1` para que adb no reescriba las rutas `/data/...`.

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
ULA+ **no** está (CLK tiene paleta fija de 16 colores y salida Red2Green2Blue2): habría que parchear
Video.hpp (puertos BF3B/FF3B, paleta de 64, bloque PLTT de .szx).

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
- **Instancia única** (`windows/runner/single_instance.cpp`): mutex `Local\EasySpectrum.SingleInstance`;
  si ya hay una ventana (marcada con la propiedad `EasySpectrum.MainWindow`), la nueva instancia le
  manda sus argumentos por `WM_COPYDATA` (rutas ya absolutas), la trae al frente y sale. El runner
  los pasa a Dart por el canal `cl.easysoft.easyspectrum/open_args` → `_onOpenArgs`.
- **Instalador** (`installer/easy_spectrum.iss`, Inno Setup 6 — se usa el de `C:\prismain\Inno Setup 6`):
  `bash build-app.sh installer` → `EasySpectrum-Setup-<ver>-<code>.exe`. Por usuario sin UAC (con
  opción "todos los usuarios"; registro en HKA), runtime VC++ copiado junto al .exe, idiomas
  es/en/pt/it/ru. Tipos: siempre en "Abrir con" (.tap .tzx .z80 .sna .szx .dsk .csw y .zip); la tarea
  "associate" (marcada) lo hace predeterminado salvo .zip. Si el usuario ya eligió otro programa con
  "usar siempre" (UserChoice), Windows no deja que un instalador lo cambie: se elige en "Abrir con".
  Verificado: instalación silenciosa, arranque desde la copia instalada y desinstalación sin restos.
- **Línea de comandos** (para PRISMA u otras herramientas):
  `EasySpectrum.exe juego.tap --model 48k|128k|+2|+2a|+3|16k`. Recargar (F2) vuelve a leer el
  archivo del disco: recompilar el .tap y F2.
- Teclado (`pc_keyboard.dart`): por posición; Shift = CAPS, Ctrl = SYM, signos por carácter con SYM
  (soltando CAPS), flechas + Alt/Tab = joystick elegido (o cursores). Cada tecla del PC recuerda lo
  que pulsó y la matriz se recalcula como unión → no quedan teclas pegadas. F2 recargar, F3 abrir,
  F5 reset, F6 cinta, F8 pausa, F11 pantalla completa. Por eso los atajos van en teclas F: Ctrl es SYM.
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
- [ ] Save states (requiere parchear CLK o serializar State)
- [x] Ediciones Free/Pro con flavors (verificado en AVD: Pro sin anuncios ni permisos publicitarios)
- [ ] IDs AdMob reales (solo Free) / política de privacidad `www.easysoft.cl/easy-spectrum/privacy.html`
- [x] Localización es/en/ru/it/pt
- [x] SNA de 128K (cargador propio) + fix de pantalla sombra en snapshots 128K (verificado con SNA sintéticos)
- [ ] Un juego que falla al cargar queda igual en "Mis juegos" (¿borrarlo o marcarlo?)
