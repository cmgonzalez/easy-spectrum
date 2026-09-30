// Núcleo de depuración (PDP — Prisma Debug Protocol, fase 1).
//
// Sin dependencias de CLK: lo incluyen a la vez la copia parcheada de ZXSpectrum.cpp (que
// llama a on_fetch() en cada búsqueda de opcode) y el bridge/servidor (que lo controlan).
//
// Cómo se detiene la CPU sin tocar el Z80 de CLK: el bus handler devuelve un "retraso" enorme
// en el ciclo de M1; el Z80 lo resta de su contador de ciclos y sale de run_for() en la
// siguiente operación de bus, con el estado intacto. Al reanudar se le devuelve ese retraso
// (credit) y continúa exactamente donde estaba. Mientras está detenido NO se debe llamar a
// run_for() (ejecutaría las microoperaciones que no tocan el bus).
#pragma once
#include <stdint.h>

namespace zxdbg {

struct Regs {
	uint16_t pc = 0, sp = 0, af = 0, bc = 0, de = 0, hl = 0;
	uint16_t af2 = 0, bc2 = 0, de2 = 0, hl2 = 0, ix = 0, iy = 0, memptr = 0;
	uint8_t i = 0, r = 0, iff1 = 0, iff2 = 0, im = 0;
};

// Lo implementa la máquina concreta (ver el parche en native/CMakeLists.txt).
struct Target {
	void *ctx = nullptr;
	void (*regs)(void *, Regs *) = nullptr;
	uint8_t (*peek)(void *, uint16_t) = nullptr;
	void (*poke)(void *, uint16_t, uint8_t) = nullptr;
	void (*credit)(void *, int64_t half_cycles) = nullptr;
};

enum class Reason : uint8_t { None, Pause, Breakpoint, Step, Until };

constexpr int64_t StopDebt = int64_t(1) << 40;	// half cycles: más que cualquier tramo de run_for

struct Core {
	Target t;
	bool armed = false;		// camino caliente: false = on_fetch ni se llama
	bool suppress = false;	// drain(): no detener
	bool stopped = false;
	bool event_pending = false;	// el bridge debe emitir el evento "stopped"
	Reason reason = Reason::None;
	uint16_t stop_pc = 0;
	Regs regs;				// registros al inicio de la instrucción en la que se detuvo
	int64_t debt = 0;

	bool pause_req = false;
	bool step_req = false;
	int until_addr = -1;	// punto de parada temporal (run until / next)
	int until_sp = -1;		// si >= 0, además SP debe coincidir (saltar llamadas recursivas)
	uint8_t bp[65536] = {};
	int bp_count = 0;

	// Seguimiento de prefijos: el ReadOpcode de CB/ED/DD/FD + opcode no es inicio de instrucción.
	uint8_t prefix = 0;
	int last_start_pc = -1;
};

inline Core g;

inline bool attached() { return g.t.ctx != nullptr; }

inline int64_t stop(uint16_t addr, Reason why) {
	Core &c = g;
	c.t.regs(c.t.ctx, &c.regs);
	c.regs.pc = addr;	// el Z80 ya tiene pc_ tocado; la instrucción empieza en `addr`
	c.stop_pc = addr;
	c.reason = why;
	c.stopped = true;
	c.event_pending = true;
	c.pause_req = c.step_req = false;
	c.until_addr = c.until_sp = -1;
	c.debt += StopDebt;
	return StopDebt;
}

// Llamado por la máquina en cada ReadOpcode, con la dirección y el opcode leído.
// Devuelve el retraso (half cycles) que debe devolver el bus handler: 0 = seguir.
inline int64_t on_fetch(uint16_t addr, uint8_t op) {
	Core &c = g;
	bool start = true;
	switch(c.prefix) {
		case 0xCB: case 0xED:
			start = false; c.prefix = 0; break;
		case 0xDD: case 0xFD:
			if(op == 0xDD || op == 0xFD || op == 0xED) c.prefix = op;	// el prefijo anterior no hacía nada
			else { start = false; c.prefix = 0; }
			break;
		default:
			if(op == 0xCB || op == 0xED || op == 0xDD || op == 0xFD) c.prefix = op;
			break;
	}
	if(!start) return 0;

	const int prev = c.last_start_pc;
	c.last_start_pc = addr;
	if(c.suppress || c.stopped) return 0;

	if(c.pause_req) return stop(addr, Reason::Pause);
	if(c.step_req) return stop(addr, Reason::Step);
	if(c.until_addr == addr) {
		if(c.until_sp < 0) return stop(addr, Reason::Until);
		Regs r; c.t.regs(c.t.ctx, &r);
		if(r.sp == c.until_sp) return stop(addr, Reason::Until);
	}
	// HALT re-busca su propio opcode en cada ciclo: solo cuenta la primera vez.
	if(c.bp[addr] && !(op == 0x76 && prev == addr)) return stop(addr, Reason::Breakpoint);
	return 0;
}

// Reanuda: devuelve a la CPU el retraso (termina la instrucción en curso). Puede volver a
// detenerse al instante si la siguiente instrucción es una parada (step, punto de parada).
inline void resume() {
	Core &c = g;
	if(!c.stopped) return;
	c.stopped = false;
	c.last_start_pc = -1;
	const int64_t d = c.debt;
	c.debt = 0;
	if(d) c.t.credit(c.t.ctx, d);
}

// Reanuda sin permitir paradas (reset / destrucción de la máquina).
inline void drain() {
	Core &c = g;
	if(!c.stopped) return;
	c.suppress = true;
	resume();
	c.suppress = false;
	c.event_pending = false;
}

inline void detach(void *ctx) {
	if(g.t.ctx == ctx) {
		g.t = Target();
		g.stopped = false;
		g.event_pending = false;
		g.debt = 0;
		g.prefix = 0;
	}
}

}  // namespace zxdbg
