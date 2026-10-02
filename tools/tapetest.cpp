// Prueba del gestor de cintas sobre el bridge real, sin Flutter (doc/TAPE_MANAGER.md).
// Uso: tapetest <carpeta_roms> <cinta.tzx>   (el .tzx debe tener >= 4 bloques)
// Usar una COPIA de las ROMs, no assets/roms: el bridge escribe ahí los recortes del seek
// (.tape_seek*) y la cinta vacía de expulsar, y esa carpeta se empaqueta en la app.
// 1) 48K BASIC: SAVE "a" con la grabación activa -> bloques capturados (header + datos).
// 2) Se escribe rec.tap, se inserta en caliente, info / seek.
// 3) <cinta.tzx>: insert + seek al bloque 1 + reproducir: el bloque tiene que avanzar.
// Verificado (2026-10-01) compilando CLK + bridge con g++ de MSYS2 UCRT64: SAVE da 19 + 2
// bytes, y una TZX recortada desde el bloque 1 avanza 1 -> 2 -> 3 en ~7 s.
#include "zx_bridge.h"
#include "Machines/Sinclair/Keyboard/Keyboard.hpp"
#include <cstdio>
#include <vector>
#include <initializer_list>

using namespace Sinclair::ZX::Keyboard;

static ZxHandle *h;
static void run(double s) { for(double t = 0; t < s; t += 0.02) zx_run(h, 0.02); }
static void press(std::initializer_list<int> keys) {
	for(int k : keys) zx_set_key(h, k, 1);
	run(0.12);
	for(int k : keys) zx_set_key(h, k, 0);
	run(0.2);
}
static void info(const char *what) {
	int b, n;
	const int f = zx_tape_info(h, &b, &n);
	printf("%-28s block=%d/%d flags=%02x\n", what, b, n, f);
}

int main(int argc, char **argv) {
	if(argc < 3) { printf("uso: tapetest <roms> <cinta.tzx>\n"); return 2; }
	const char *roms = argv[1];
	h = zx_create(roms, 1, "", 48000);
	if(!h) { printf("create: %s\n", zx_last_error()); return 1; }
	run(3);
	zx_tape_record(h, 1);
	press({KeyS});	// SAVE
	press({KeySymbolShift, KeyP});
	press({KeyA});
	press({KeySymbolShift, KeyP});
	press({KeyEnter});
	run(1);
	press({KeySpace});	// "Start tape, then press any key"
	run(4);
	const int pending = zx_tape_take_recorded(h, nullptr, 0);
	std::vector<uint8_t> rec(size_t(pending) + 1);
	const int got = zx_tape_take_recorded(h, rec.data(), pending);
	printf("SAVE grabado: %d bytes pendientes, %d tomados\n", pending, got);
	for(int p = 0; p + 2 <= got;) {
		const int len = rec[p] | (rec[p + 1] << 8);
		printf("  bloque len=%d flag=%02x", len, rec[p + 2]);
		if(rec[p + 2] == 0) printf(" tipo=%d nombre='%.10s'", rec[p + 3], (const char *)&rec[p + 4]);
		printf("\n");
		p += 2 + len;
	}
	zx_tape_record(h, 0);
	FILE *f = fopen("rec.tap", "wb");
	fwrite(rec.data(), 1, size_t(got), f);
	fclose(f);

	printf("insert rec.tap: %d\n", zx_tape_insert(h, "rec.tap"));
	info("tras insertar");
	printf("seek 1: %d\n", zx_tape_seek(h, 1));
	info("tras seek 1");

	printf("insert %s: %d\n", argv[2], zx_tape_insert(h, argv[2]));
	info("tras insertar tzx");
	printf("seek 1: %d\n", zx_tape_seek(h, 1));
	info("tras seek 1 (tzx)");
	zx_set_tape_playing(h, 1);
	zx_set_quickload(h, 0);
	for(int i = 0; i < 12; i++) { run(1); info("reproduciendo"); }
	zx_tape_set_paused(h, 1);
	run(1);
	info("en pausa");
	zx_tape_set_paused(h, 0);
	run(1);
	info("reanudada");
	zx_tape_eject(h);
	info("expulsada");
	zx_destroy(h);
	return 0;
}
