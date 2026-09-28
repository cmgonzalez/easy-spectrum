#include "zx_bridge.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char **argv) {
	const char *media = argc > 1 ? argv[1] : "";
	int model = argc > 2 ? atoi(argv[2]) : 1;
	double secs = argc > 3 ? atof(argv[3]) : 3.0;
	ZxHandle *h = zx_create("/data/local/tmp/zx", model, media, 48000);
	if(!h) { printf("create failed: %s\n", zx_last_error()); return 1; }
	int frames = 0; long audio = 0; static int16_t buf[65536];
	for(double t = 0; t < secs; t += 0.02) {
		frames += zx_run(h, 0.02);
		audio += zx_get_audio(h, buf, 65536);
	}
	printf("frames=%d audio_samples=%ld\n", frames, audio);
	const uint8_t *fb = zx_get_framebuffer(h);
	FILE *f = fopen("/data/local/tmp/zx/out.ppm", "wb");
	fprintf(f, "P6 %d %d 255\n", ZX_FB_WIDTH, ZX_FB_HEIGHT);
	for(int i = 0; i < ZX_FB_WIDTH * ZX_FB_HEIGHT; i++) fwrite(fb + i * 4, 1, 3, f);
	fclose(f);
	zx_destroy(h);
	return 0;
}
