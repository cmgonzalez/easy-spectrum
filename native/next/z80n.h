// Z80 + extensiones Z80N de la ZX Spectrum Next. Núcleo propio (no deriva de CLK ni de otros
// emuladores): escrito a partir de la documentación pública del Z80 y del wiki de SpecNext.
// Temporización por instrucción (T-states estándar, sin contención).
#pragma once
#include <cstdint>

namespace nx {

class Z80Bus {
public:
	virtual uint8_t read(uint16_t addr) = 0;
	virtual void write(uint16_t addr, uint8_t value) = 0;
	virtual uint8_t in(uint16_t port) = 0;
	virtual void out(uint16_t port, uint8_t value) = 0;
	virtual void nextreg(uint8_t reg, uint8_t value) = 0;
	virtual uint8_t int_vector() { return 0xFF; }	// byte que el dispositivo pone en el bus (IM 2)
	virtual void reti_executed() {}
protected:
	~Z80Bus() = default;
};

class Z80N {
public:
	explicit Z80N(Z80Bus &bus): bus_(bus) { reset(); }
	void reset();

	// Ejecuta una instrucción (o acepta una interrupción) y devuelve los T-states usados.
	int step();

	// Línea INT (nivel). La máquina la sube y baja.
	bool int_line = false;
	// Petición de NMI (flanco): se atiende en el siguiente step().
	bool nmi_request = false;

	uint8_t A, F, B, C, D, E, H, L;
	uint8_t A2, F2, B2, C2, D2, E2, H2, L2;
	uint16_t IX, IY, SP, PC;
	uint8_t I, R;
	bool IFF1, IFF2, halted;
	uint8_t IM;

	uint16_t BC() const { return uint16_t(B << 8 | C); }
	uint16_t DE() const { return uint16_t(D << 8 | E); }
	uint16_t HL() const { return uint16_t(H << 8 | L); }
	void setBC(uint16_t v) { B = uint8_t(v >> 8); C = uint8_t(v); }
	void setDE(uint16_t v) { D = uint8_t(v >> 8); E = uint8_t(v); }
	void setHL(uint16_t v) { H = uint8_t(v >> 8); L = uint8_t(v); }

private:
	Z80Bus &bus_;
	bool ei_delay_ = false;	// EI retrasa la aceptación de interrupciones una instrucción
	int t_ = 0;

	uint8_t rd(uint16_t a) { return bus_.read(a); }
	void wr(uint16_t a, uint8_t v) { bus_.write(a, v); }
	uint8_t fetch() { return bus_.read(PC++); }
	uint16_t fetch16() { uint8_t l = fetch(); uint8_t h = fetch(); return uint16_t(h << 8 | l); }
	uint16_t rd16(uint16_t a) { uint8_t l = rd(a); uint8_t h = rd(uint16_t(a + 1)); return uint16_t(h << 8 | l); }
	void wr16(uint16_t a, uint16_t v) { wr(a, uint8_t(v)); wr(uint16_t(a + 1), uint8_t(v >> 8)); }
	void push(uint16_t v) { SP -= 2; wr16(SP, v); }
	uint16_t pop() { uint16_t v = rd16(SP); SP += 2; return v; }

	uint8_t get_r(int idx, int pfx, uint16_t addr);
	void set_r(int idx, int pfx, uint16_t addr, uint8_t v);
	uint16_t get_rp(int p, int pfx);
	void set_rp(int p, int pfx, uint16_t v);
	uint16_t get_rp2(int p, int pfx);
	void set_rp2(int p, int pfx, uint16_t v);
	bool cond(int cc) const;

	uint8_t alu(int op, uint8_t a, uint8_t b);
	uint8_t inc8(uint8_t v);
	uint8_t dec8(uint8_t v);
	uint16_t add16(uint16_t a, uint16_t b);
	void adc16(uint16_t b);
	void sbc16(uint16_t b);
	uint8_t rot(int op, uint8_t v);
	void daa();
	void exec_cb(int pfx, uint16_t ixaddr, bool have_disp);
	void exec_ed();
	void block_ld(int dir, bool repeat);
	void block_cp(int dir, bool repeat);
	void block_in(int dir, bool repeat);
	void block_out(int dir, bool repeat);
	void exec_z80n(uint8_t op);
	void set_szp_xy(uint8_t v);
	void interrupt_accept();
};

}	// namespace nx
