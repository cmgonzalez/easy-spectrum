// Prueba del Z80 con zexdoc/zexall (CP/M mínimo: BDOS 2 y 9). Uso: z80test zexdoc.com
#include "../native/next/z80n.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

struct CpmBus : nx::Z80Bus {
	uint8_t mem[65536];
	uint8_t read(uint16_t a) override { return mem[a]; }
	void write(uint16_t a, uint8_t v) override { mem[a] = v; }
	uint8_t in(uint16_t) override { return 0xFF; }
	void out(uint16_t, uint8_t) override {}
	void nextreg(uint8_t, uint8_t) override {}
};

int main(int argc, char **argv) {
	if(argc < 2) return 1;
	FILE *f = fopen(argv[1], "rb");
	if(!f) { printf("no file\n"); return 1; }
	static CpmBus bus;
	memset(bus.mem, 0, sizeof(bus.mem));
	size_t n = fread(bus.mem + 0x100, 1, 0xFE00, f);
	fclose(f);
	bus.mem[0] = 0x76;	// HALT en 0 (warm boot)
	bus.mem[5] = 0xC9;	// RET en BDOS
	nx::Z80N cpu(bus);
	cpu.PC = 0x100;
	cpu.SP = 0xF000;
	unsigned long long steps = 0;
	while(true) {
		if(cpu.PC == 0) break;
		if(cpu.PC == 5) {
			if(cpu.C == 2) putchar(cpu.E);
			else if(cpu.C == 9) {
				uint16_t a = cpu.DE();
				while(bus.mem[a] != '$') putchar(bus.mem[a++]);
			}
			fflush(stdout);
		}
		cpu.step();
		++steps;
	}
	printf("\nfin tras %llu instrucciones (%zu bytes)\n", steps, n);
	return 0;
}
