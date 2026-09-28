// Harness del core sin Flutter: arranca la máquina, llama a zx_run() como lo haría
// el Ticker (ticks de 20 ms) durante <segundos> de reloj y vuelca out.ppm.
// Uso: zxtest <media|""> <modelo> <segundos> [carga_rapida=1]
// Ver CLAUDE.md → "Probar el core sin Flutter".
#include "zx_bridge.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

int main(int argc, char **argv) {
	const char *media = argc > 1 ? argv[1] : "";
	const int model = argc > 2 ? atoi(argv[2]) : 1;
	const double secs = argc > 3 ? atof(argv[3]) : 3.0;
	const int quick = argc > 4 ? atoi(argv[4]) : 1;

	ZxHandle *h = zx_create("/data/local/tmp/zx", model, media, 48000);
	if(!h) { printf("create failed: %s\n", zx_last_error()); return 1; }
	zx_set_quickload(h, quick);

	// Ritmo real: cada tick espera a completar sus 20 ms, como el vsync de Flutter.
	using Clock = std::chrono::steady_clock;
	int frames = 0; long audio = 0; static int16_t buf[65536];
	const int ticks = int(secs / 0.02);
	auto next = Clock::now();
	for(int i = 0; i < ticks; i++) {
		frames += zx_run(h, 0.02);
		audio += zx_get_audio(h, buf, 65536);
		next += std::chrono::milliseconds(20);
		std::this_thread::sleep_until(next);
	}
	printf("reloj=%.1fs emulado=%.1fs frames=%d audio_samples=%ld cinta=%d\n",
		secs, zx_get_emulated_time(h), frames, audio, zx_get_tape_playing(h));

	const uint8_t *fb = zx_get_framebuffer(h);
	FILE *f = fopen("/data/local/tmp/zx/out.ppm", "wb");
	fprintf(f, "P6 %d %d 255\n", ZX_FB_WIDTH, ZX_FB_HEIGHT);
	for(int i = 0; i < ZX_FB_WIDTH * ZX_FB_HEIGHT; i++) fwrite(fb + i * 4, 1, 3, f);
	fclose(f);
	zx_destroy(h);
	return 0;
}
