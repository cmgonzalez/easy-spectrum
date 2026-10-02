#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Handle opaco de una instancia del emulador (core: Clock Signal / CLK). */
typedef struct ZxHandle ZxHandle;

/* Framebuffer de salida: 256×192 de pantalla + 32 px de borde por lado. */
#define ZX_FB_WIDTH  320
#define ZX_FB_HEIGHT 256

/* Modelos — mismo orden que Analyser::Static::ZXSpectrum::Target::Model. */
#define ZX_MODEL_16K    0
#define ZX_MODEL_48K    1
#define ZX_MODEL_128K   2
#define ZX_MODEL_PLUS2  3
#define ZX_MODEL_PLUS2A 4
#define ZX_MODEL_PLUS3  5
#define ZX_MODEL_NEXT   6	/* ZX Spectrum Next: solo archivos .nex (máquina propia, sin CLK) */

/* Joystick (Kempston + Sinclair a la vez) — bitmask de zx_set_joystick. */
#define ZX_JOY_UP    (1u << 0)
#define ZX_JOY_DOWN  (1u << 1)
#define ZX_JOY_LEFT  (1u << 2)
#define ZX_JOY_RIGHT (1u << 3)
#define ZX_JOY_FIRE  (1u << 4)

/*
 * zx_create — crea la máquina.
 *   rom_dir:    carpeta con 48.rom, 128.rom, plus2.rom, plus3.rom.
 *   model:      ZX_MODEL_* (ignorado si media_path es un snapshot: manda el snapshot).
 *   media_path: .tap .tzx .csw .z80 .sna .szx .dsk .nex — o NULL/"" para arrancar en BASIC.
 *   audio_freq: tasa de salida (ej. 48000). Audio: s16le estéreo intercalado.
 * Devuelve NULL si falla (ROM ausente, archivo inválido). zx_last_error() da el motivo.
 */
ZxHandle* zx_create(const char* rom_dir, int model, const char* media_path, int audio_freq);

/* Código del último error de zx_create (estático, no liberar):
 * bad_snapshot, cpc_snapshot, unsupported_format, machine_failed, missing_roms, open_failed, bad_nex,
 * o el texto de la excepción de CLK si no es ninguno de esos. */
const char* zx_last_error(void);

void zx_destroy(ZxHandle* h);

/* Avanza la emulación `seconds` segundos de tiempo real. Devuelve frames completados. */
int zx_run(ZxHandle* h, double seconds);

/* Segundos emulados desde zx_create (con turbo de carga avanza más rápido que el reloj). */
double zx_get_emulated_time(ZxHandle* h);

/* 1 si el último zx_run corrió en turbo de carga (cinta girando). */
int zx_is_turbo(ZxHandle* h);

/* Modelo real de la máquina (ZX_MODEL_*; manda el snapshot si lo hay, ZX_MODEL_NEXT para .nex). */
int zx_get_model(ZxHandle* h);

/* 1 si el programa activó la paleta ULAplus (puerto FF3B, modo 1). */
int zx_is_ulaplus(ZxHandle* h);

/* Framebuffer RGBA8888 ZX_FB_WIDTH×ZX_FB_HEIGHT del último frame completo. */
const uint8_t* zx_get_framebuffer(ZxHandle* h);

/* Tecla de la matriz: key = (fila << 8) | bit, igual que Sinclair::ZX::Keyboard::Key. */
void zx_set_key(ZxHandle* h, int key, int pressed);
void zx_clear_keys(ZxHandle* h);

/* Escribe texto con el Typer de CLK (ej. "j\"\"\n" = LOAD "" en 48K). */
void zx_type(ZxHandle* h, const char* utf8);

void zx_set_joystick(ZxHandle* h, int mask);

/* Ratón: mode 0 = sin ratón, 1 = Kempston, 2 = AMX. dx/dy son desplazamientos relativos
 * (dy positivo = hacia abajo); buttons: bit 0 izquierdo, bit 1 derecho, bit 2 central. */
void zx_set_mouse_mode(ZxHandle* h, int mode);
void zx_mouse_move(ZxHandle* h, int dx, int dy);
void zx_mouse_buttons(ZxHandle* h, int buttons);

/* Drena audio: hasta max_samples int16 (L,R,L,R…). Devuelve cuántos int16 copió. */
int zx_get_audio(ZxHandle* h, int16_t* out, int max_samples);

void zx_reset(ZxHandle* h);

/* Control de cinta (play/stop manual; con motor automático normalmente no hace falta). */
void zx_set_tape_playing(ZxHandle* h, int playing);
int  zx_get_tape_playing(ZxHandle* h);

/* Gestor de cintas (doc/TAPE_MANAGER.md). Los bloques se numeran igual que el parser de Dart
 * (lib/core/tape/tape_file.dart): en .tap cada bloque con su longitud; en .tzx cada bloque
 * tras la cabecera de 10 bytes (incluidos texto, pausas y bloques de control). */
#define ZX_TAPE_INSERTED  (1 << 0)	/* hay cinta (.csw incluida, sin lista de bloques) */
#define ZX_TAPE_PLAYING   (1 << 1)	/* motor encendido y cinta sin terminar */
#define ZX_TAPE_END       (1 << 2)	/* la cinta llegó al final */
#define ZX_TAPE_PAUSED    (1 << 3)	/* pausa: motor apagado y sin arranque automático */
#define ZX_TAPE_RECORDING (1 << 4)	/* capturando los SAVE del ROM */

/* Inserta una cinta (.tap .tzx .csw) con la máquina en marcha. 1 = bien. */
int  zx_tape_insert(ZxHandle* h, const char* path);
/* Expulsa la cinta (queda una vacía). */
void zx_tape_eject(ZxHandle* h);
/* Mueve la cinta al inicio del bloque `block` (0 = rebobinar; total = fin). Conserva el motor. */
int  zx_tape_seek(ZxHandle* h, int block);
/* Estado: devuelve ZX_TAPE_*; block = bloque que suena (total = fin), total = nº de bloques. */
int  zx_tape_info(ZxHandle* h, int* block, int* total);
/* Pausa (1): motor apagado y sin motor automático; 0 = reanudar (enciende el motor). */
void zx_tape_set_paused(ZxHandle* h, int paused);
/* Grabación: con 1, cada SAVE que pase por SA-BYTES del ROM se guarda como bloque .tap. */
void zx_tape_record(ZxHandle* h, int enabled);
/* Bloques grabados pendientes en formato .tap (longitud + bloque). out = NULL: devuelve
 * los bytes pendientes; si no, copia bloques enteros (hasta max bytes) y los quita. */
int  zx_tape_take_recorded(ZxHandle* h, uint8_t* out, int max);

/* Carga rápida de cinta. 1 = activada (defecto): trap de la rutina del ROM (.tap)
 * más turbo de emulación mientras gira la cinta (cargadores propios, .tzx). */
void zx_set_quickload(ZxHandle* h, int enabled);

/* Gigascreen: 1 = cada frame se mezcla con el anterior (en luz lineal). Defecto 0. */
void zx_set_gigascreen(ZxHandle* h, int enabled);

/* Depuracion PDP (Prisma Debug Protocol, doc/PDP.md): abre un servidor TCP en 127.0.0.1:<port>
 * (0 = puerto libre). Devuelve el puerto, o -1 si falla. Solo una maquina a la vez. */
int  zx_pdp_start(ZxHandle* h, int port);
void zx_pdp_stop(ZxHandle* h);

/* Multiplicador de velocidad (1.0 = normal). */
void zx_set_speed(ZxHandle* h, double multiplier);

#ifdef __cplusplus
}
#endif
