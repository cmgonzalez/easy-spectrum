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
 *   media_path: .tap .tzx .csw .z80 .sna .szx .dsk — o NULL/"" para arrancar en BASIC.
 *   audio_freq: tasa de salida (ej. 48000). Audio: s16le estéreo intercalado.
 * Devuelve NULL si falla (ROM ausente, archivo inválido). zx_last_error() da el motivo.
 */
ZxHandle* zx_create(const char* rom_dir, int model, const char* media_path, int audio_freq);

/* Texto del último error de zx_create (estático, no liberar). */
const char* zx_last_error(void);

void zx_destroy(ZxHandle* h);

/* Avanza la emulación `seconds` segundos de tiempo real. Devuelve frames completados. */
int zx_run(ZxHandle* h, double seconds);

/* Framebuffer RGBA8888 ZX_FB_WIDTH×ZX_FB_HEIGHT del último frame completo. */
const uint8_t* zx_get_framebuffer(ZxHandle* h);

/* Tecla de la matriz: key = (fila << 8) | bit, igual que Sinclair::ZX::Keyboard::Key. */
void zx_set_key(ZxHandle* h, int key, int pressed);
void zx_clear_keys(ZxHandle* h);

/* Escribe texto con el Typer de CLK (ej. "j\"\"\n" = LOAD "" en 48K). */
void zx_type(ZxHandle* h, const char* utf8);

void zx_set_joystick(ZxHandle* h, int mask);

/* Drena audio: hasta max_samples int16 (L,R,L,R…). Devuelve cuántos int16 copió. */
int zx_get_audio(ZxHandle* h, int16_t* out, int max_samples);

void zx_reset(ZxHandle* h);

/* Control de cinta (play/stop manual; con motor automático normalmente no hace falta). */
void zx_set_tape_playing(ZxHandle* h, int playing);
int  zx_get_tape_playing(ZxHandle* h);

/* Carga rápida de cinta (trap de ROM). 1 = activada (defecto). */
void zx_set_quickload(ZxHandle* h, int enabled);

/* Multiplicador de velocidad (1.0 = normal). */
void zx_set_speed(ZxHandle* h, double multiplier);

#ifdef __cplusplus
}
#endif
