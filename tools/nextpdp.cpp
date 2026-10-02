// Host headless de la Next con servidor PDP (sin Flutter ni CLK), para probar el depurador.
//   clang++ -std=c++17 -O2 tools/nextpdp.cpp native/zx_pdp.cpp native/next/*.cpp -lws2_32 -o nextpdp.exe
//   nextpdp juego.nex [puerto] [segundos]
#include "../native/next/next_machine.h"
#include "../native/zx_pdp.h"
#include "../native/zx_debug.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

static bool read_all(const char *p, std::vector<uint8_t> &out) {
	FILE *f = fopen(p, "rb");
	if(!f) return false;
	fseek(f, 0, SEEK_END);
	const long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	out.resize(size_t(n));
	const size_t r = fread(out.data(), 1, size_t(n), f);
	fclose(f);
	return r == size_t(n);
}

int main(int argc, char **argv) {
	if(argc < 2) { printf("uso: nextpdp archivo.nex [puerto] [segundos]\n"); return 1; }
	const int port = argc > 2 ? atoi(argv[2]) : 7878;
	const double limit = argc > 3 ? atof(argv[3]) : 0;
	std::vector<uint8_t> rom, nex;
	if(!read_all("C:/dev/easy-spectrum/assets/roms/48.rom", rom) || !read_all(argv[1], nex)) { printf("sin rom o nex\n"); return 1; }

	nx::NextMachine m(48000);
	m.set_rom(rom.data(), rom.size());
	std::string err;
	if(!m.load_nex(nex.data(), nex.size(), err)) { printf("nex: %s\n", err.c_str()); return 1; }
	m.attach_debugger();

	pdp::Host host;
	host.machine = "next";
	host.emulated_seconds = [&] { return m.emulated_seconds(); };
	host.reset = [&] { std::string e; m.load_nex(nex.data(), nex.size(), e); };
	host.frame = [&] { return m.frame(); };
	host.set_key = [&](int key, bool down) { m.set_key(key, down); };
	host.set_joy = [&](int mask) { m.set_joystick(mask); };

	const int p = pdp::start(port);
	if(p < 0) { printf("no se pudo abrir el puerto\n"); return 1; }
	printf("PDP escuchando en 127.0.0.1:%d\n", p);
	fflush(stdout);

	std::vector<int16_t> buf(65536);
	const auto t0 = std::chrono::steady_clock::now();
	auto next = t0;
	for(;;) {
		pdp::pump(host);
		if(!zxdbg::g.stopped) m.run(0.02);
		pdp::pump(host);
		m.drain_audio(buf.data(), int(buf.size()));
		next += std::chrono::milliseconds(20);
		std::this_thread::sleep_until(next);
		if(limit > 0 && std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > limit) break;
	}
	pdp::stop();
	m.detach_debugger();
	return 0;
}
