// Harness de la máquina Next sin Flutter: carga un .nex, corre N segundos emulados y vuelca out.ppm.
// Uso: nextest <archivo.nex> <segundos> [salida.ppm] [rom48] [teclas...]
#include "../native/next/next_machine.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static bool read_all(const char *p, std::vector<uint8_t> &out) {
	FILE *f = fopen(p, "rb");
	if(!f) return false;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	out.resize(n);
	size_t r = fread(out.data(), 1, n, f);
	fclose(f);
	return r == size_t(n);
}

int main(int argc, char **argv) {
	if(argc < 3) { printf("uso: nextest archivo.nex segundos [out.ppm] [48.rom]\n"); return 1; }
	const char *out_path = argc > 3 ? argv[3] : "out.ppm";
	const char *rom_path = argc > 4 ? argv[4] : "C:/dev/easy-spectrum/assets/roms/48.rom";
	std::vector<uint8_t> rom, nex;
	if(!read_all(rom_path, rom)) { printf("sin rom\n"); return 1; }
	if(!read_all(argv[1], nex)) { printf("sin nex\n"); return 1; }

	nx::NextMachine m(48000);
	m.set_rom(rom.data(), rom.size());
	m.trace_regs = getenv("NX_TRACE") != nullptr;
	{
		std::string p = argv[1];
		const size_t slash = p.find_last_of("/\\");
		m.set_data_dir(getenv("NX_DIR") ? getenv("NX_DIR") : (slash == std::string::npos ? "." : p.substr(0, slash)));
	}
	std::string err;
	if(!m.load_nex(nex.data(), nex.size(), err)) { printf("error: %s\n", err.c_str()); return 1; }

	const double secs = atof(argv[2]);
	int frames = 0;
	long audio = 0;
	static int16_t buf[1 << 16];
	auto t0 = std::chrono::steady_clock::now();
	// NX_KEYS="tiempo:tecla:1|0;..." (tecla en hex, p. ej. 1.0:0x0504:1;1.2:0x0504:0)
	struct Ev { double t; int key; int down; };
	std::vector<Ev> evs;
	if(const char *k = getenv("NX_KEYS")) {
		double t; int key, down; int n = 0;
		while(sscanf(k + n, "%lf:%i:%d", &t, &key, &down) == 3) {
			evs.push_back({t, key, down});
			const char *semi = strchr(k + n, ';');
			if(!semi) break;
			n = int(semi - k) + 1;
		}
	}
	size_t evi = 0;
	const int ticks = int(secs / 0.02);
	for(int i = 0; i < ticks; i++) {
		while(evi < evs.size() && evs[evi].t <= i * 0.02) { m.set_key(evs[evi].key, evs[evi].down); ++evi; }
		frames += m.run(0.02);
		audio += m.drain_audio(buf, 1 << 16);
	}
	double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	printf("emulado=%.2fs real=%.2fs (x%.1f) frames=%d audio=%ld instr=%llu PC=%04X speed=%d\n",
		m.emulated_seconds(), wall, m.emulated_seconds() / wall, frames, audio,
		(unsigned long long)m.total_instructions(), m.cpu().PC, m.cpu_speed());

	if(const char *d = getenv("NX_DUMP")) {
		int a = 0, n = 0;
		sscanf(d, "%i,%i", &a, &n);
		for(int i = 0; i < n; ++i) printf("%02X%c", m.peek(uint16_t(a + i)), (i % 40 == 39) ? 10 : 32);
		printf("%c", 10);
	}
	if(getenv("NX_REGS")) {
		for(int r = 0; r < 256; ++r) if(m.next_reg(r)) printf("R%02X=%02X ", r, m.next_reg(r));
		printf("\n");
	}
	if(getenv("NX_PIX")) {
		int x = 0, y = 0;
		sscanf(getenv("NX_PIX"), "%d,%d", &x, &y);
		int o[4];
		m.debug_pixel(y, x, o);
		printf("pixel (%d,%d): ula=%d tile=%d l2=%d spr=%d\n", x, y, o[0], o[1], o[2], o[3]);
		for(int i = 0; i < 4; ++i) printf("ulapal[%d]=%03X ", 16 + i, m.debug_pal(0, 16 + i));
		printf("\n");
	}
	FILE *f = fopen(out_path, "wb");
	fprintf(f, "P6 %d %d 255\n", nx::kFbWidth, nx::kFbHeight);
	const uint8_t *fb = m.frame();
	for(int i = 0; i < nx::kFbWidth * nx::kFbHeight; i++) fwrite(fb + i * 4, 1, 3, f);
	fclose(f);
	return 0;
}
