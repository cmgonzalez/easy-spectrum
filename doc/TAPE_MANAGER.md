# Gestor de cintas (Tape Manager) — planificación

## Estado de la implementación (2026-10-01)

| Fase | Estado | Verificación |
|---|---|---|
| 1 — lista de bloques | `lib/core/tape/tape_file.dart` (TAP + TZX, emparejado cabecera/datos, checksum) | `test/tape_file_test.dart` escrito, **sin correr** (no había Flutter en la máquina) |
| 2 — posición, seek, insertar/expulsar, pausa | nativo + `TapeController` + UI Windows/Android | **nativo verificado** con `tools/tapetest.cpp` (CLK real + ROMs, g++ MSYS2); UI sin compilar |
| 3.1 — grabar SAVE | trap de SA-BYTES 0x04C2 (parche CMake `cinta-grabar`) | **verificado**: `SAVE "a"` en 48K → header 19 + datos 2 bytes |
| 3.2 — cinta nueva desde archivos | `tape_builder.dart`, `zx_basic.dart` (tokenizador), `tape_editor.dart` | test escrito, sin correr |
| 4 — pulido | checksum ✓/✗, TZX→TAP, "Añadir a Mis juegos" (Android), atajos Shift+F8/F6 | — |

**Decisiones respecto al plan:**
- **Posición (spike 1)**: no hizo falta envolver `Tape`. CLK lee cada bloque en un solo punto
  (`ZXSpectrumTAP::read_next_block`, `TZX::push_next_pulses`) justo cuando empieza a sonar: dos
  parches CMake sobre copias de esos `.cpp` avisan el offset a `zxtape::note_block`
  (`native/zx_tape.h`) y el bridge lo traduce a índice con el mismo escáner que Dart
  (`scan_tap`/`scan_tzx`). Sirve también con el trap de carga rápida (lee del mismo serialiser).
  Verificado: los offsets avisados coinciden 1:1 con el escáner en TAP y TZX, fin de cinta incluido.
- **Seek (spike 2)**: recorte `bloques N..fin` (en `.tzx` con la cabecera de 10 bytes) en
  `<roms>/.tape_seek{0,1}.{tap,tzx}` (dos nombres alternados: CLK tiene abierto el anterior) +
  `insert_media`. Conserva el motor. CLK ignora saltos/bucles TZX (0x23-0x26), así que el
  recorte no rompe nada que el reproductor respetara.
- **Pausa ≠ stop**: pausa apaga el motor **y el motor automático** (si no, el cargador que
  sigue leyendo el puerto FE la vuelve a arrancar); stop = pausa + volver al inicio del bloque.
- **Grabación**: siempre a un `.tap` aparte (no la cinta insertada: CLK la tiene abierta y en
  Windows no se puede reemplazar un archivo abierto). Al terminar se ofrece insertarla.
  Android: `save.tap` nuevo en Mis juegos (`GameLibrary.freePath`).
- **Cassette de Android**: dibujado por código (`tape_deck.dart`, `CustomPainter`) en vez de
  arte generado por `make_skins.py`; se puede sustituir por arte más adelante sin tocar la
  lógica. Se muestra solo al abrir un juego de cinta y vuelve al mando al terminar la carga.
- **Escritorio**: panel acoplado a la derecha (la ventana se ensancha, como con el teclado).
  Shift+F8 rebobinar, F8 play/pausa, F6 panel, F7 insertar; Máquina › Rebobinar / Insertar / Expulsar / Gestor /
  Crear cinta.

**Pendiente**: autocarga como conmutador (hoy siempre activa en `zx_create`), compartir en
Android (no hay `share_plus`; se guarda por el selector del sistema o en Mis juegos), arte
propio del cassette, importar TAP desde `.zip` en el editor, y probar todo en Windows/AVD/S24+.

Objetivo: un gestor de cintas como el *Cassette Recorder* de ZEsarUX/Fuse (ver captura de referencia):
lista de bloques de la cinta insertada, controles de transporte (grabar, play, pausa, stop, rebobinar,
avanzar, expulsar), estado "Block N of M", y poder **crear cintas nuevas** y editarlas.

> **Alcance: Windows y Android.** Parser, editor, modelo y bindings FFI (`lib/core/tape/`, `zx_bridge`) son
> comunes; la UI es distinta: panel/diálogo con lista en Windows, y en Android un **cassette en lugar del
> teclado/mando** con la info en el LCD. Las fases 1-3 se implementan una vez y cada fase se entrega con ambas UIs.

## Qué hay hoy

- `zx_bridge.cpp`: la cinta se inserta **solo al crear la máquina** (`ZXSpectrumTAP`/`TZX`/`CSW` por ruta
  en `target->media.tapes`). Solo existen `zx_set_tape_playing` / `zx_get_tape_playing` (motor).
- UI: F6 / menú ⋮ "Reproducir/Detener cinta"; la barra de Windows ya tiene un `ToolItem('tape', '… (Próximamente)')`
  y otro `'guardar'` reservados en `desktop_screen.dart`.
- `GameThumbnail` ya recorre bloques de .tap/.tzx en Dart (cabeceras, longitudes) → base del parser.
- CLK **no** expone posición de cinta, rebobinado, ni grabación para el Spectrum.

## Alcance por fases

### Fase 1 — Ver la cinta (solo lectura, solo Dart)
- `lib/core/tape/tape_file.dart`: parser de `.tap` y `.tzx` → `List<TapeBlock>`
  (`index`, `kind` [Program/Number array/Char array/Bytes/Data/Pause/Text/Turbo/Pure tone…], `name`,
  `length`, `param1/param2` [LINE o dirección,longitud], `flag`, `checksumOk`, `offset` en el archivo).
  Texto como en la captura: `Program: Civtopia LINE 10`, `Bytes: screen CODE 16384,6912`,
  `Normal Data Block (241 bytes)`. Empareja cabecera + bloque de datos en una sola fila lógica (opción de verlos sueltos).
- `.csw` y `.z80/.sna`: sin lista (solo "cinta de audio").
- Pantalla `TapeManagerScreen` / panel (ver "UI"). Fila seleccionada ≠ posición de cinta aún.
- Tests Dart del parser con los .tap/.tzx de `tools/` (incluye TZX con bloques 0x10/0x11/0x12/0x13/0x14/0x20/0x30/0x32).

### Fase 2 — Controlar la cinta insertada (nativo)
Necesita saber en qué bloque está la cinta y poder moverla.
- **Envoltorio propio de cinta** en el bridge (`TrackedTape : Storage::Tape::Tape`) que delega en la cinta
  original y cuenta bloques/pulsos → posición = (bloque, progreso). Spike previo: confirmar que
  `Tape::serialiser()` permite envolverlo y detectar el límite de bloque (si no, plan B: la posición se
  deduce en Dart contando bloques completados por el trap `LD-BYTES` y el motor).
- **Seek / rebobinar / avanzar**: rearmar la cinta desde el bloque N. Los constructores de CLK solo
  leen de ruta, así que se genera un archivo temporal con los bloques N..M (`.tap`, o `.tzx` con cabecera)
  y se reinserta con `insert_media`. Rebobinar = bloque 0.
- **Insertar / expulsar en caliente** sin reiniciar la máquina (hoy exige `zx_create`):
  `zx_tape_insert(h, path)`, `zx_tape_eject(h)`, `zx_tape_info(h, &block, &total, &playing)`.
- API FFI nueva (`zx_bridge.h` + `zx_bridge.dart`): `zx_tape_seek(h, block)`, `zx_tape_rewind`,
  `zx_tape_insert/eject/info`. Mantener `zx_set/get_tape_playing`.
- Pausa ≠ stop: pausa conserva posición (motor apagado); stop vuelve al inicio del bloque actual.
- Interacción con el **turbo**: el turbo ya depende de "motor encendido + cinta sin terminar"; el contador
  de bloque debe seguir en turbo. "Cinta terminada" pasa a ser un estado visible ("End of tape").

### Fase 3 — Grabar (SAVE) y crear cintas nuevas
Dos caminos, complementarios:
1. **Grabar lo que el Spectrum guarda** (`SAVE "x"`, `SAVE "x" CODE …`):
   interceptar `SA-BYTES` del ROM (0x04C2, mismo mecanismo que el trap de carga; verificar la
   dirección en los ROM de 128K/+2/+3, que usan el ROM 48 BASIC para esto) y volcar el bloque
   (flag + datos + checksum) a un buffer. El bridge expone `zx_tape_rec_start/stop/take_blocks`.
   Funciona con SAVE estándar; los guardadores con rutina propia (turbo) no se capturan — se documenta.
   El botón ● alterna "grabando": los bloques se **añaden** a la cinta destino (`.tap`).
2. **Cinta nueva desde archivos** (sin emulación): editor en Dart que arma un `.tap`:
   - Añadir bloque desde archivo binario (nombre ≤10 chars, dirección de carga → `CODE`),
     pantalla `.scr` (→ `Bytes: screen CODE 16384,6912`), programa BASIC pegado/`.bas` (LINE),
     o bloque de datos crudo.
   - Plantilla "cargador": cabecera BASIC `LOAD "" CODE` + CODE + `RANDOMIZE USR n` (pensado para
     PRISMA: de .bin + dirección a .tap listo).
   - Reordenar (arrastrar), renombrar, borrar, duplicar bloques; exportar `.tap` (y `.tzx` si hay bloques turbo).
- Guardado/escritura siempre atómico (`.part` + rename), igual que `GameLibrary.import`.

### Fase 4 — Pulido
- Convertir TZX → TAP cuando solo hay bloques estándar; importar TAP desde `.zip`.
- Guardar la cinta resultante en la biblioteca ("Mis juegos") o exportarla (selector de archivo / compartir en Android).
- Validación: checksum por bloque con ✓/✗; aviso de bloque corrupto.
- Atajos Windows (F6 play ya existe; añadir rebobinar/expulsar), accesibilidad (botones ≥64 dp en móvil).

## UI

**Windows** (ventana/diálogo no modal, estilo Spectrum negro; inspirado en la captura):
- Cabecera: nombre del archivo. Lista de bloques con la fila de la posición resaltada y autoscroll.
- Barra de transporte: ● grabar · ▶ play · ⏸ pausa · ■ stop · ⏪ ⏩ bloque anterior/siguiente · ⏏ expulsar.
- Barra de estado: icono cinta + `Stopped / Playing / Recording` y `Block N of M`.
- Conmutadores arriba: turbo/carga rápida, autocarga, silenciar sonido de cinta.
- Se abre desde el `ToolItem('tape')` ya reservado y desde Máquina › Gestor de cintas. Doble clic en un bloque = mover la cinta ahí.

Implementación Windows: ventana secundaria o panel acoplable dentro de `DesktopApp` (`lib/features/desktop/`);
se recomienda un panel/diálogo en la misma ventana (el menú nativo Win32 ya existe: añadir entradas en Máquina y
el atajo). Escritura de archivos con el selector nativo (`file_selector`/el que ya use `_pickFile`) y arrastrar y
soltar (`desktop_drop`) sobre la lista para añadir bloques desde archivos. Verificación con la instalación local
(`bash build-app.sh windows`) y captura PrintWindow.

**Android** (UI distinta a Windows, dentro de la consola portátil `ConsoleView`):
- **Tercer modo del área de controles**: además de mando y teclado, el área inferior puede mostrar una
  **grabadora de cassette** (`TapeDeck`), con arte propio en el mismo estilo que las pieles (generado por
  `tools/make_skins.py` desde `art/`, tabla de geometría como `_clusters`). La pantalla del juego, el LCD y la fila
  de `ActionButtons` no cambian de sitio.
- **Cassette dibujado**: ventanilla con la cinta y dos carretes que giran mientras corre (más rápido en
  avance/rebobinado, parados en pausa; un Ticker propio que no reconstruye el resto), y debajo las teclas
  mecánicas: ● REC · ▶ PLAY · ⏪ REW · ⏩ FF · ■ STOP/⏏ (pausa) con relieve/hundido al pulsarlas y vibración
  (`lib/core/haptics.dart`). Zonas táctiles grandes (≥64 dp). Contador mecánico de 3 dígitos = bloque actual.
- **Info en el LCD** (`LcdPanel`, el letrero en bucle ya existente): en modo cinta muestra
  `Block 3/34 · Bytes: screen CODE 16384,6912 · Playing` (estado: Stopped/Playing/Paused/Rec/End); al saltar de
  bloque se pinta unos segundos el nombre del bloque. Las mitades ENTER | ESPACIO siguen funcionando.
- **Cómo se accede**: el botón verde ya alterna mando/teclado; pasa a rotar mando → teclado → cassette
  (el ícono refleja el modo siguiente), y también hay "Cinta" en el menú ⋮. Si el juego es de cinta, al
  terminar la carga el modo vuelve solo al mando guardado en `PadConfig`.
- **Lista completa de bloques / editor de cintas nuevas**: no cabe en el cassette → hoja inferior
  (`showModalBottomSheet`) abierta tocando el LCD o la ventanilla del cassette: lista de bloques (tocar = mover la
  cinta ahí), y desde ahí "Crear cinta" (pantalla aparte; archivos con el selector del sistema/SAF; resultado a
  la biblioteca o compartir). Reutiliza `TapeController` y la lista de Windows (comunes).
- Piezas nuevas: `lib/features/tape/tape_deck.dart` (cassette), `assets/skin/tape_*.png` (cuerpo, carretes,
  teclas), entradas de `make_skins.py`. Verificar en AVD y en el S24+ (ambos ABIs).

Textos: añadir a los 5 ARB (es plantilla, en, ru, it, pt) y `flutter gen-l10n`; reutilizar `tapeBrowser`, `playTape`, `stopTape`.

## Archivos previstos

```
lib/core/tape/tape_file.dart          parser + modelo TapeBlock
lib/core/tape/tape_builder.dart       armar/exportar .tap (fase 3)
lib/features/tape/tape_manager.dart   panel/pantalla (lista + transporte + estado)
lib/features/tape/tape_editor.dart    editor de cinta nueva (fase 3)
native/zx_bridge.{h,cpp}              TrackedTape, insert/eject/seek/info, grabación SAVE
lib/core/emulator/zx_bridge.dart      bindings nuevos
test/tape_file_test.dart              parser
```

## Riesgos / puntos a validar (spikes)

1. ¿Se puede envolver `Tape` de CLK para contar bloques sin romper el trap de `LD-BYTES` ni el detector de
   motor? Si no → posición deducida desde Dart.
2. Insertar cinta con la máquina en marcha (`insert_media`): comprobar que reinicia el estado del reproductor.
3. Dirección de `SA-BYTES` por modelo; que el trap no interfiera con el ROM de 128K en modo 48 BASIC.
4. Seek con TZX que tiene bloques de control (loops 0x24/0x25, saltos 0x23, "stop the tape if 48K" 0x2A):
   al re-cortar el TZX hay que respetar su estado; en el primer corte, rechazar seek dentro de loops.
5. Rendimiento de la lista con cintas grandes (cientos de bloques): `ListView.builder`.

## Orden de entrega sugerido

1. Fase 1 (valor inmediato, sin tocar nativo, rápido de verificar en Windows).
2. Fase 2: núcleo nativo probado primero con `tools/zxtest.cpp` (sin Flutter), luego UI en Windows y Android
   (ambos ABIs: arm64-v8a y x86_64).
3. Fase 3.2 (cinta desde archivos, pura Dart) antes que 3.1 (captura SAVE, la parte con más riesgo).
4. Fase 4.
