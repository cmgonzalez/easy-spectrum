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
#include <map>
#include <vector>

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

enum class Reason : uint8_t { None, Pause, Breakpoint, Step, Until, Watch, Crash };

// Condición simple "lhs OP valor": lhs = registro o byte/palabra de memoria ([addr] / [addr]w).
enum RegId : int8_t { R_PC, R_SP, R_AF, R_BC, R_DE, R_HL, R_IX, R_IY, R_A, R_F, R_B, R_C, R_D, R_E, R_H, R_L,
	R_I, R_R, R_IFF1, R_IFF2, R_IM, R_NONE = -1 };
enum CondOp : uint8_t { C_EQ, C_NE, C_LT, C_GT, C_LE, C_GE, C_AND };

struct Cond {
	bool on = false;
	int8_t reg = R_NONE;	// si es R_NONE, lhs = memoria
	int32_t mem = 0;
	bool word = false;
	CondOp op = C_EQ;
	int32_t val = 0;
};

struct WatchEntry {
	uint16_t addr = 0, len = 1;
	uint8_t kind = 2;		// bit0 lectura, bit1 escritura
	bool has_val = false;	// solo escrituras de este valor
	uint8_t val = 0;
	Cond cond;
};

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
	std::map<uint16_t, Cond> bp_cond;

	// Watchpoints (hook en los ciclos Read/Write de la máquina).
	bool watch_any = false;
	std::vector<WatchEntry> watches;
	uint8_t wmask[65536] = {};
	uint16_t hit_addr = 0; uint8_t hit_val = 0; bool hit_write = false;

	// Historial de PC (inicio de cada instrucción) y detección de caídas.
	bool hist_on = false;
	std::vector<uint16_t> hist;
	uint32_t hmask = 0, hpos = 0, hcount = 0;
	bool catch_reset = false, catch_nmi = false, catch_rom = false, catch_dihalt = false, catch_any = false;
	const char *detail = "";
	int from_pc = -1;		// instrucción anterior a la parada (para caídas)

	// Seguimiento de prefijos: el ReadOpcode de CB/ED/DD/FD + opcode no es inicio de instrucción.
	uint8_t prefix = 0;
	int last_start_pc = -1;
};

inline Core g;

inline bool attached() { return g.t.ctx != nullptr; }

inline uint32_t reg_get(const Regs &r, int id) {
	switch(id) {
		case R_PC: return r.pc; case R_SP: return r.sp; case R_AF: return r.af; case R_BC: return r.bc;
		case R_DE: return r.de; case R_HL: return r.hl; case R_IX: return r.ix; case R_IY: return r.iy;
		case R_A: return r.af >> 8; case R_F: return r.af & 0xff; case R_B: return r.bc >> 8; case R_C: return r.bc & 0xff;
		case R_D: return r.de >> 8; case R_E: return r.de & 0xff; case R_H: return r.hl >> 8; case R_L: return r.hl & 0xff;
		case R_I: return r.i; case R_R: return r.r; case R_IFF1: return r.iff1; case R_IFF2: return r.iff2; case R_IM: return r.im;
	}
	return 0;
}

// Evalúa con los registros vivos; `pc` = inicio de la instrucción (el Z80 ya movió pc_).
inline bool eval(const Cond &c, uint16_t pc) {
	if(!c.on) return true;
	uint32_t l;
	if(c.reg != R_NONE) {
		Regs r; g.t.regs(g.t.ctx, &r); r.pc = pc;
		l = reg_get(r, c.reg);
	} else {
		l = g.t.peek(g.t.ctx, uint16_t(c.mem));
		if(c.word) l |= uint32_t(g.t.peek(g.t.ctx, uint16_t(c.mem + 1))) << 8;
	}
	const uint32_t v = uint32_t(c.val);
	switch(c.op) {
		case C_EQ: return l == v; case C_NE: return l != v; case C_LT: return l < v;
		case C_GT: return l > v; case C_LE: return l <= v; case C_GE: return l >= v;
		case C_AND: return (l & v) != 0;
	}
	return true;
}

inline void hist_init(uint32_t entries_pow2) {
	g.hist.assign(entries_pow2, 0);
	g.hmask = entries_pow2 - 1; g.hpos = 0; g.hcount = 0;
}

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

	if(c.hist_on) {
		c.hist[c.hpos] = addr;
		c.hpos = (c.hpos + 1) & c.hmask;
		if(c.hcount <= c.hmask) ++c.hcount;
	}

	if(c.pause_req) return stop(addr, Reason::Pause);
	if(c.step_req) return stop(addr, Reason::Step);
	if(c.until_addr == addr) {
		if(c.until_sp < 0) return stop(addr, Reason::Until);
		Regs r; c.t.regs(c.t.ctx, &r);
		if(r.sp == c.until_sp) return stop(addr, Reason::Until);
	}

	if(c.catch_any) {
		const char *why = nullptr;
		if(prev >= 0x4000 && addr < 0x4000) {
			if(addr == 0 && c.catch_reset) why = "reset";
			else if(addr == 0x66 && c.catch_nmi) why = "nmi";
			else if(addr != 0x38 && c.catch_rom) why = "rom";
		} else if(op == 0x76 && prev != addr && c.catch_dihalt) {
			Regs r; c.t.regs(c.t.ctx, &r);
			if(!r.iff1) why = "di_halt";
		}
		if(why) { c.detail = why; c.from_pc = prev; return stop(addr, Reason::Crash); }
	}

	// HALT re-busca su propio opcode en cada ciclo: solo cuenta la primera vez.
	if(c.bp[addr] && !(op == 0x76 && prev == addr)) {
		const auto it = c.bp_cond.find(addr);
		if(it == c.bp_cond.end() || eval(it->second, addr)) return stop(addr, Reason::Breakpoint);
	}
	return 0;
}

// Llamado por la máquina tras cada ciclo Read/Write (con el valor leído/escrito). Se detiene
// a mitad de instrucción, con el acceso ya hecho; el pc que se informa es el de su inicio.
inline int64_t on_mem(uint16_t addr, uint8_t val, bool write) {
	Core &c = g;
	if(c.suppress || c.stopped) return 0;
	const uint8_t bit = write ? 2 : 1;
	if(!(c.wmask[addr] & bit)) return 0;
	for(const auto &w : c.watches) {
		if(uint16_t(addr - w.addr) >= w.len || !(w.kind & bit)) continue;
		if(write && w.has_val && val != w.val) continue;
		const uint16_t pc = c.last_start_pc >= 0 ? uint16_t(c.last_start_pc) : 0;
		if(!eval(w.cond, pc)) continue;
		c.hit_addr = addr; c.hit_val = val; c.hit_write = write;
		return stop(pc, Reason::Watch);
	}
	return 0;
}

// Reanuda: devuelve a la CPU el retraso (termina la instrucción en curso). Puede volver a
// detenerse al instante si la siguiente instrucción es una parada (step, punto de parada).
inline void resume() {
	Core &c = g;
	if(!c.stopped) return;
	c.stopped = false;
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
