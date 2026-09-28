# CLAUDE.md — Easy Spectrum

Emulador de ZX Spectrum en Flutter para Android (iOS preparado, sin probar).
Paquete: `cl.easysoft.easyspectrum` — Repo: https://github.com/cmgonzalez/easy-spectrum
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

## Probar el core sin Flutter

`tools/zxtest.cpp`: ejecutable que arranca la máquina, corre N segundos y vuelca `out.ppm`.
Compilar con el clang del NDK (target `x86_64-linux-android24` para el AVD, `aarch64` para el S26),
push a `/data/local/tmp/zx/` junto con las ROMs, y ejecutar `./zxtest juego.tap <modelo> <segundos>`.
En Git Bash usar `MSYS_NO_PATHCONV=1` para que adb no reescriba las rutas `/data/...`.

---

## Dart

```
lib/core/emulator/zx_bridge.dart   FFI (start/run/frame/keys/joystick/audio/tape)
lib/core/emulator/zx_types.dart    ZxModel, ZxKey (fila<<8|bit), ZxJoy, JoyMapping
lib/core/settings.dart             AppSettings (SharedPreferences)
lib/core/storage/game_library.dart juegos importados → <appDocs>/games (+ .zip)
lib/features/game/                 game_screen (Ticker, reloj de pared), zx_keyboard, joystick_pad
```

- Loop: cada tick de vsync se llama `zx_run(delta real)`; delta >0,1 s se descarta (pausa).
- Teclado: multitáctil con `Listener`; CAPS/SYM se fijan con un toque y se sueltan tras la siguiente tecla.
- Joystick: Kempston (por defecto), Sinclair, Cursor o QAOP+Espacio (estos tres simulan teclas).

## Idiomas

`gen-l10n` con ARB en `lib/l10n/`: **es** (plantilla), en, ru, it, pt. Los `app_localizations*.dart`
se generan al compilar (están en `.gitignore`). Acceso con `context.l10n` (`lib/core/l10n.dart`).
El inglés es el idioma de reserva para locales no soportados.
- Añadir un texto: agregarlo a los 5 ARB (con `@clave`/placeholders solo en `app_es.arb`) y `flutter gen-l10n`.
- `zx_last_error()` devuelve códigos (`missing_roms`, `bad_snapshot`…) que traduce `zxErrorText()`.
- Probar un idioma en el emulador sin cambiar el sistema:
  `adb shell cmd locale set-app-locales cl.easysoft.easyspectrum --locales ru`

## Build

```powershell
& "C:\Users\cmgon\dev-tools\flutter\bin\flutter.bat" build apk --debug
& "C:\Users\cmgon\dev-tools\flutter\bin\flutter.bat" build appbundle
```
Firma release: `android/key.properties` (no va al repo). Primera compilación nativa ~5 min (CLK × 2 ABIs).

## Estado

- [x] Core CLK compilando en Android (arm64/x86_64), 50 fps, audio 48 kHz
- [x] Carga de cinta verificada en 48K y +2 (Max Stone Dos, .tap)
- [x] UI: biblioteca, teclado ZX, joystick, ajustes, acerca de
- [x] APK release verificado en AVD (BASIC 128K, carga .tap, teclado, juego jugable)
- [ ] Probar en SM S926B (audio real)
- [ ] Save states (requiere parchear CLK o serializar State)
- [ ] IDs AdMob reales / política de privacidad `www.easysoft.cl/easy-spectrum/privacy.html`
- [x] Localización es/en/ru/it/pt
- [ ] SNA de 128K (131 KB): CLK solo carga SNA de 48K → escribir cargador propio en el bridge
