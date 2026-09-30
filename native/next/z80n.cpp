#include "z80n.h"

#include <algorithm>

namespace nx {

namespace {
constexpr uint8_t fS = 0x80, fZ = 0x40, fY = 0x20, fH = 0x10, fX = 0x08, fP = 0x04, fN = 0x02, fC = 0x01;

struct ParityTable {
	bool even[256];
	constexpr ParityTable(): even() {
		for(int i = 0; i < 256; ++i) {
			int v = i, bits = 0;
			while(v) { bits += v & 1; v >>= 1; }
			even[i] = (bits & 1) == 0;
		}
	}
};
constexpr ParityTable parity_table;
inline uint8_t parity(uint8_t v) { return parity_table.even[v] ? fP : 0; }
}	// namespace

void Z80N::reset() {
	A = F = B = C = D = E = H = L = 0xFF;
	A2 = F2 = B2 = C2 = D2 = E2 = H2 = L2 = 0xFF;
	IX = IY = 0xFFFF;
	SP = 0xFFFF;
	PC = 0;
	I = R = 0;
	IFF1 = IFF2 = false;
	halted = false;
	IM = 0;
	ei_delay_ = false;
	int_line = false;
	nmi_request = false;
}

uint8_t Z80N::get_r(int idx, int pfx, uint16_t addr) {
	switch(idx) {
		case 0: return B;
		case 1: return C;
		case 2: return D;
		case 3: return E;
		case 4: return pfx == 0 ? H : uint8_t((pfx == 1 ? IX : IY) >> 8);
		case 5: return pfx == 0 ? L : uint8_t(pfx == 1 ? IX : IY);
		case 6: return rd(addr);
		default: return A;
	}
}

void Z80N::set_r(int idx, int pfx, uint16_t addr, uint8_t v) {
	switch(idx) {
		case 0: B = v; break;
		case 1: C = v; break;
		case 2: D = v; break;
		case 3: E = v; break;
		case 4:
			if(pfx == 0) H = v;
			else if(pfx == 1) IX = uint16_t(v << 8 | (IX & 0xFF));
			else IY = uint16_t(v << 8 | (IY & 0xFF));
			break;
		case 5:
			if(pfx == 0) L = v;
			else if(pfx == 1) IX = uint16_t((IX & 0xFF00) | v);
			else IY = uint16_t((IY & 0xFF00) | v);
			break;
		case 6: wr(addr, v); break;
		default: A = v; break;
	}
}

uint16_t Z80N::get_rp(int p, int pfx) {
	switch(p) {
		case 0: return BC();
		case 1: return DE();
		case 2: return pfx == 0 ? HL() : (pfx == 1 ? IX : IY);
		default: return SP;
	}
}

void Z80N::set_rp(int p, int pfx, uint16_t v) {
	switch(p) {
		case 0: setBC(v); break;
		case 1: setDE(v); break;
		case 2:
			if(pfx == 0) setHL(v);
			else if(pfx == 1) IX = v;
			else IY = v;
			break;
		default: SP = v; break;
	}
}

uint16_t Z80N::get_rp2(int p, int pfx) {
	return p == 3 ? uint16_t(A << 8 | F) : get_rp(p, pfx);
}

void Z80N::set_rp2(int p, int pfx, uint16_t v) {
	if(p == 3) { A = uint8_t(v >> 8); F = uint8_t(v); }
	else set_rp(p, pfx, v);
}

bool Z80N::cond(int cc) const {
	switch(cc) {
		case 0: return !(F & fZ);
		case 1: return F & fZ;
		case 2: return !(F & fC);
		case 3: return F & fC;
		case 4: return !(F & fP);
		case 5: return F & fP;
		case 6: return !(F & fS);
		default: return F & fS;
	}
}

void Z80N::set_szp_xy(uint8_t v) {
	F = uint8_t((v & (fS | fY | fX)) | (v == 0 ? fZ : 0) | parity(v));
}

uint8_t Z80N::alu(int op, uint8_t a, uint8_t b) {
	int r;
	switch(op) {
		case 0:	// ADD
		case 1: {	// ADC
			const int c = (op == 1 && (F & fC)) ? 1 : 0;
			r = a + b + c;
			F = uint8_t((r & (fS | fY | fX)) | ((r & 0xFF) == 0 ? fZ : 0)
				| ((a ^ b ^ r) & fH) | ((((a ^ r) & (b ^ r)) & 0x80) ? fP : 0) | (r > 0xFF ? fC : 0));
			return uint8_t(r);
		}
		case 2:	// SUB
		case 3:	// SBC
		case 7: {	// CP
			const int c = (op == 3 && (F & fC)) ? 1 : 0;
			r = a - b - c;
			uint8_t xy = uint8_t(r & (fS | fY | fX));
			if(op == 7) xy = uint8_t((b & (fY | fX)) | (r & fS));
			F = uint8_t(xy | ((r & 0xFF) == 0 ? fZ : 0) | fN
				| ((a ^ b ^ r) & fH) | ((((a ^ b) & (a ^ r)) & 0x80) ? fP : 0) | ((r & 0x100) ? fC : 0));
			return op == 7 ? a : uint8_t(r);
		}
		case 4:	// AND
			r = a & b;
			set_szp_xy(uint8_t(r));
			F |= fH;
			return uint8_t(r);
		case 5:	// XOR
			r = a ^ b;
			set_szp_xy(uint8_t(r));
			return uint8_t(r);
		default:	// OR
			r = a | b;
			set_szp_xy(uint8_t(r));
			return uint8_t(r);
	}
}

uint8_t Z80N::inc8(uint8_t v) {
	const uint8_t r = uint8_t(v + 1);
	F = uint8_t((F & fC) | (r & (fS | fY | fX)) | (r == 0 ? fZ : 0) | ((v & 0x0F) == 0x0F ? fH : 0) | (v == 0x7F ? fP : 0));
	return r;
}

uint8_t Z80N::dec8(uint8_t v) {
	const uint8_t r = uint8_t(v - 1);
	F = uint8_t((F & fC) | (r & (fS | fY | fX)) | (r == 0 ? fZ : 0) | ((v & 0x0F) == 0 ? fH : 0) | (v == 0x80 ? fP : 0) | fN);
	return r;
}

uint16_t Z80N::add16(uint16_t a, uint16_t b) {
	const uint32_t r = uint32_t(a) + b;
	F = uint8_t((F & (fS | fZ | fP)) | ((r >> 8) & (fY | fX)) | (((a ^ b ^ r) & 0x1000) ? fH : 0) | (r > 0xFFFF ? fC : 0));
	return uint16_t(r);
}

void Z80N::adc16(uint16_t b) {
	const uint16_t a = HL();
	const uint32_t c = (F & fC) ? 1 : 0;
	const uint32_t r = uint32_t(a) + b + c;
	F = uint8_t(((r >> 8) & (fS | fY | fX)) | ((r & 0xFFFF) == 0 ? fZ : 0) | (((a ^ b ^ r) & 0x1000) ? fH : 0)
		| ((((a ^ r) & (b ^ r)) & 0x8000) ? fP : 0) | (r > 0xFFFF ? fC : 0));
	setHL(uint16_t(r));
}

void Z80N::sbc16(uint16_t b) {
	const uint16_t a = HL();
	const uint32_t c = (F & fC) ? 1 : 0;
	const uint32_t r = uint32_t(a) - b - c;
	F = uint8_t(((r >> 8) & (fS | fY | fX)) | ((r & 0xFFFF) == 0 ? fZ : 0) | (((a ^ b ^ r) & 0x1000) ? fH : 0)
		| ((((a ^ b) & (a ^ r)) & 0x8000) ? fP : 0) | fN | ((r & 0x10000) ? fC : 0));
	setHL(uint16_t(r));
}

uint8_t Z80N::rot(int op, uint8_t v) {
	uint8_t r, c;
	switch(op) {
		case 0: c = v >> 7; r = uint8_t(v << 1 | c); break;	// RLC
		case 1: c = v & 1; r = uint8_t(v >> 1 | c << 7); break;	// RRC
		case 2: c = v >> 7; r = uint8_t(v << 1 | (F & fC)); break;	// RL
		case 3: c = v & 1; r = uint8_t(v >> 1 | (F & fC) << 7); break;	// RR
		case 4: c = v >> 7; r = uint8_t(v << 1); break;	// SLA
		case 5: c = v & 1; r = uint8_t(v >> 1 | (v & 0x80)); break;	// SRA
		case 6: c = v >> 7; r = uint8_t(v << 1 | 1); break;	// SLL
		default: c = v & 1; r = uint8_t(v >> 1); break;	// SRL
	}
	set_szp_xy(r);
	F |= c;
	return r;
}

void Z80N::daa() {
	uint8_t corr = 0;
	uint8_t c = F & fC;
	if((F & fH) || (A & 0x0F) > 9) corr |= 0x06;
	if(c || A > 0x99) { corr |= 0x60; c = fC; }
	const uint8_t a = A;
	A = (F & fN) ? uint8_t(A - corr) : uint8_t(A + corr);
	const uint8_t h = (F & fN) ? (((F & fH) && (a & 0x0F) < 6) ? fH : 0) : ((a & 0x0F) > 9 ? fH : 0);
	F = uint8_t((F & fN) | c | h | (A & (fS | fY | fX)) | (A == 0 ? fZ : 0) | parity(A));
}

void Z80N::exec_cb(int pfx, uint16_t addr, bool have_disp) {
	const uint8_t op = fetch();
	if(!have_disp) { R = uint8_t((R & 0x80) | ((R + 1) & 0x7F)); }
	const int x = op >> 6, y = (op >> 3) & 7, z = op & 7;
	const bool mem = have_disp || z == 6;
	if(!mem) t_ += 8; else t_ += (have_disp ? 12 : (x == 1 ? 8 : 12));
	if(!have_disp && z == 6) addr = HL();
	const uint8_t v = mem ? rd(addr) : get_r(z, 0, 0);
	if(x == 1) {
		const uint8_t m = uint8_t(v & (1 << y));
		F = uint8_t((F & fC) | fH | (m ? 0 : (fZ | fP)) | (m & fS)
			| ((mem ? (addr >> 8) : v) & (fY | fX)));
		return;
	}
	uint8_t r;
	if(x == 0) r = rot(y, v);
	else if(x == 2) r = uint8_t(v & ~(1 << y));
	else r = uint8_t(v | (1 << y));
	if(mem) {
		wr(addr, r);
		if(have_disp && z != 6) set_r(z, 0, 0, r);	// copia no documentada al registro
	} else set_r(z, 0, 0, r);
	(void)pfx;
}

void Z80N::block_ld(int dir, bool repeat) {
	const uint8_t v = rd(HL());
	wr(DE(), v);
	setHL(uint16_t(HL() + dir));
	setDE(uint16_t(DE() + dir));
	setBC(uint16_t(BC() - 1));
	const uint8_t n = uint8_t(v + A);
	F = uint8_t((F & (fS | fZ | fC)) | (n & fX) | ((n & 0x02) ? fY : 0) | (BC() ? fP : 0));
	t_ += 16;
	if(repeat && BC()) { PC -= 2; t_ += 5; }
}

void Z80N::block_cp(int dir, bool repeat) {
	const uint8_t v = rd(HL());
	const uint8_t r = uint8_t(A - v);
	const uint8_t h = uint8_t((A ^ v ^ r) & fH);
	setHL(uint16_t(HL() + dir));
	setBC(uint16_t(BC() - 1));
	const uint8_t n = uint8_t(r - (h ? 1 : 0));
	F = uint8_t((F & fC) | (r & fS) | (r == 0 ? fZ : 0) | h | (n & fX) | ((n & 0x02) ? fY : 0) | (BC() ? fP : 0) | fN);
	t_ += 16;
	if(repeat && BC() && r != 0) { PC -= 2; t_ += 5; }
}

void Z80N::block_in(int dir, bool repeat) {
	const uint8_t v = bus_.in(BC());
	wr(HL(), v);
	B = uint8_t(B - 1);
	setHL(uint16_t(HL() + dir));
	const int k = v + ((C + dir) & 0xFF);
	F = uint8_t((B & (fS | fY | fX)) | (B == 0 ? fZ : 0) | ((v & 0x80) ? fN : 0)
		| (k > 255 ? (fH | fC) : 0) | parity(uint8_t((k & 7) ^ B)));
	t_ += 16;
	if(repeat && B) { PC -= 2; t_ += 5; }
}

void Z80N::block_out(int dir, bool repeat) {
	const uint8_t v = rd(HL());
	B = uint8_t(B - 1);
	bus_.out(BC(), v);
	setHL(uint16_t(HL() + dir));
	const int k = v + L;
	F = uint8_t((B & (fS | fY | fX)) | (B == 0 ? fZ : 0) | ((v & 0x80) ? fN : 0)
		| (k > 255 ? (fH | fC) : 0) | parity(uint8_t((k & 7) ^ B)));
	t_ += 16;
	if(repeat && B) { PC -= 2; t_ += 5; }
}

// Instrucciones propias de la Z80N (prefijo ED). Devuelve sin hacer nada si `op` no es Z80N.
void Z80N::exec_z80n(uint8_t op) {
	switch(op) {
		case 0x23: A = uint8_t(A << 4 | A >> 4); break;	// SWAPNIB
		case 0x24: {	// MIRROR A
			uint8_t r = 0;
			for(int i = 0; i < 8; ++i) if(A & (1 << i)) r |= uint8_t(0x80 >> i);
			A = r; break;
		}
		case 0x27: {	// TEST n
			const uint8_t n = fetch();
			const uint8_t r = A & n;
			set_szp_xy(r);
			F |= fH;
			t_ += 3; break;
		}
		case 0x28: setDE(uint16_t(DE() << std::min(B & 31, 16))); break;	// BSLA DE,B
		case 0x29: setDE(uint16_t(int16_t(DE()) >> (B & 31))); break;	// BSRA
		case 0x2A: setDE(uint16_t(DE() >> (B & 31))); break;	// BSRL
		case 0x2B: setDE(uint16_t(~(uint16_t(~DE()) >> (B & 31)))); break;	// BSRF
		case 0x2C: {	// BRLC DE,B
			const int n = B & 15;
			const uint16_t v = DE();
			setDE(uint16_t((v << n) | (v >> ((16 - n) & 15))));
			break;
		}
		case 0x30: setDE(uint16_t(D * E)); break;	// MUL D,E
		case 0x31: setHL(uint16_t(HL() + A)); break;
		case 0x32: setDE(uint16_t(DE() + A)); break;
		case 0x33: setBC(uint16_t(BC() + A)); break;
		case 0x34: setHL(uint16_t(HL() + fetch16())); t_ += 8; break;
		case 0x35: setDE(uint16_t(DE() + fetch16())); t_ += 8; break;
		case 0x36: setBC(uint16_t(BC() + fetch16())); t_ += 8; break;
		case 0x8A: {	// PUSH nn (el operando va en orden big-endian)
			const uint8_t hi = fetch();
			const uint8_t lo = fetch();
			push(uint16_t(hi << 8 | lo));
			t_ += 15; break;
		}
		case 0x90: {	// OUTINB
			const uint8_t v = rd(HL());
			bus_.out(BC(), v);
			setHL(uint16_t(HL() + 1));
			t_ += 8; break;
		}
		case 0x91: { const uint8_t r = fetch(); const uint8_t v = fetch(); bus_.nextreg(r, v); t_ += 12; break; }
		case 0x92: { const uint8_t r = fetch(); bus_.nextreg(r, A); t_ += 9; break; }
		case 0x93: {	// PIXELDN
			uint8_t h = H, l = L;
			h++;
			if((h & 7) == 0) {
				const int nl = l + 32;
				l = uint8_t(nl);
				if(nl <= 0xFF) h = uint8_t(h - 8);
			}
			H = h; L = l; break;
		}
		case 0x94: {	// PIXELAD
			setHL(uint16_t(0x4000 + ((D & 0xC0) << 5) + ((D & 7) << 8) + ((D & 0x38) << 2) + (E >> 3)));
			break;
		}
		case 0x95: A = uint8_t(0x80 >> (E & 7)); break;	// SETAE
		case 0x98: {	// JP (C)
			const uint8_t v = bus_.in(BC());
			PC = uint16_t((PC & 0xC000) | (v << 6));
			t_ += 5; break;
		}
		case 0xA4: case 0xAC: {	// LDIX / LDDX
			const uint8_t v = rd(HL());
			if(v != A) wr(DE(), v);
			setHL(uint16_t(HL() + (op == 0xA4 ? 1 : -1)));
			setDE(uint16_t(DE() + 1));
			setBC(uint16_t(BC() - 1));
			t_ += 8; break;
		}
		case 0xA5: {	// LDWS
			wr(DE(), rd(HL()));
			L = uint8_t(L + 1);
			const uint8_t c = F & fC;
			D = inc8(D);
			F = uint8_t((F & ~fC) | c);
			t_ += 6; break;
		}
		case 0xB4: case 0xBC: {	// LDIRX / LDDRX
			const uint8_t v = rd(HL());
			if(v != A) wr(DE(), v);
			setHL(uint16_t(HL() + (op == 0xB4 ? 1 : -1)));
			setDE(uint16_t(DE() + 1));
			setBC(uint16_t(BC() - 1));
			t_ += 8;
			if(BC()) { PC -= 2; t_ += 5; }
			break;
		}
		case 0xB7: {	// LDPIRX
			const uint16_t src = uint16_t((HL() & 0xFFF8) | (E & 7));
			const uint8_t v = rd(src);
			if(v != A) wr(DE(), v);
			setDE(uint16_t(DE() + 1));
			setBC(uint16_t(BC() - 1));
			t_ += 8;
			if(BC()) { PC -= 2; t_ += 5; }
			break;
		}
		default: break;
	}
}

static bool is_z80n(uint8_t op) {
	switch(op) {
		case 0x23: case 0x24: case 0x27: case 0x28: case 0x29: case 0x2A: case 0x2B: case 0x2C:
		case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: case 0x35: case 0x36:
		case 0x8A: case 0x90: case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x98:
		case 0xA4: case 0xA5: case 0xAC: case 0xB4: case 0xB7: case 0xBC:
			return true;
		default: return false;
	}
}

void Z80N::exec_ed() {
	const uint8_t op = fetch();
	R = uint8_t((R & 0x80) | ((R + 1) & 0x7F));
	t_ += 4;
	if(is_z80n(op)) { exec_z80n(op); return; }

	const int x = op >> 6, y = (op >> 3) & 7, z = op & 7, p = y >> 1, q = y & 1;
	if(x == 1) {
		switch(z) {
			case 0: {
				const uint8_t v = bus_.in(BC());
				F = uint8_t((F & fC) | (v & (fS | fY | fX)) | (v == 0 ? fZ : 0) | parity(v));
				if(y != 6) set_r(y, 0, 0, v);
				t_ += 8; break;
			}
			case 1:
				bus_.out(BC(), y == 6 ? 0 : get_r(y, 0, 0));
				t_ += 8; break;
			case 2:
				if(q == 0) sbc16(get_rp(p, 0)); else adc16(get_rp(p, 0));
				t_ += 11; break;
			case 3: {
				const uint16_t a = fetch16();
				if(q == 0) wr16(a, get_rp(p, 0)); else set_rp(p, 0, rd16(a));
				t_ += 16; break;
			}
			case 4: {	// NEG
				const uint8_t a = A;
				A = 0;
				A = alu(2, 0, a);
				t_ += 4; break;
			}
			case 5:	// RETN / RETI
				IFF1 = IFF2;
				PC = pop();
				if(y == 1) bus_.reti_executed();
				t_ += 10; break;
			case 6:
				IM = uint8_t((y & 3) < 2 ? 0 : (y & 3) - 1);
				t_ += 4; break;
			default:
				switch(y) {
					case 0: I = A; t_ += 5; break;
					case 1: R = A; t_ += 5; break;
					case 2:
						A = I;
						F = uint8_t((F & fC) | (A & (fS | fY | fX)) | (A == 0 ? fZ : 0) | (IFF2 ? fP : 0));
						t_ += 5; break;
					case 3:
						A = R;
						F = uint8_t((F & fC) | (A & (fS | fY | fX)) | (A == 0 ? fZ : 0) | (IFF2 ? fP : 0));
						t_ += 5; break;
					case 4: {	// RRD
						const uint8_t m = rd(HL());
						wr(HL(), uint8_t((A << 4) | (m >> 4)));
						A = uint8_t((A & 0xF0) | (m & 0x0F));
						F = uint8_t((F & fC) | (A & (fS | fY | fX)) | (A == 0 ? fZ : 0) | parity(A));
						t_ += 14; break;
					}
					case 5: {	// RLD
						const uint8_t m = rd(HL());
						wr(HL(), uint8_t((m << 4) | (A & 0x0F)));
						A = uint8_t((A & 0xF0) | (m >> 4));
						F = uint8_t((F & fC) | (A & (fS | fY | fX)) | (A == 0 ? fZ : 0) | parity(A));
						t_ += 14; break;
					}
					default: break;
				}
		}
		return;
	}
	if(x == 2 && y >= 4 && z <= 3) {
		const int dir = (y & 1) ? -1 : 1;
		const bool rep = y >= 6;
		switch(z) {
			case 0: block_ld(dir, rep); break;
			case 1: block_cp(dir, rep); break;
			case 2: block_in(dir, rep); break;
			default: block_out(dir, rep); break;
		}
	}
	// El resto de ED es NOP de 8 T.
}

void Z80N::interrupt_accept() {
	halted = false;
	IFF1 = IFF2 = false;
	R = uint8_t((R & 0x80) | ((R + 1) & 0x7F));
	if(IM < 2) {
		push(PC);
		PC = 0x38;
		t_ += 13;
	} else {
		const uint8_t vec = bus_.int_vector();
		push(PC);
		PC = rd16(uint16_t(I << 8 | vec));
		t_ += 19;
	}
}

int Z80N::step() {
	t_ = 0;
	if(nmi_request) {
		nmi_request = false;
		halted = false;
		IFF2 = IFF1;
		IFF1 = false;
		push(PC);
		PC = 0x66;
		return 11;
	}
	const bool can_int = !ei_delay_;
	ei_delay_ = false;
	if(int_line && IFF1 && can_int) {
		interrupt_accept();
		return t_;
	}
	if(halted) {
		R = uint8_t((R & 0x80) | ((R + 1) & 0x7F));
		return 4;
	}

	int pfx = 0;
	uint8_t op;
	for(;;) {
		op = fetch();
		R = uint8_t((R & 0x80) | ((R + 1) & 0x7F));
		t_ += 4;
		if(op == 0xDD) pfx = 1;
		else if(op == 0xFD) pfx = 2;
		else break;
	}

	const int x = op >> 6, y = (op >> 3) & 7, z = op & 7, p = y >> 1, q = y & 1;
	const uint16_t ixr = pfx == 1 ? IX : IY;
	// Dirección efectiva del operando (HL) o (IX+d); el desplazamiento se lee antes del inmediato.
	auto mem_addr = [&]() -> uint16_t {
		if(pfx == 0) return HL();
		const int8_t d = int8_t(fetch());
		t_ += 5;
		return uint16_t(ixr + d);
	};

	switch(x) {
		case 0:
			switch(z) {
				case 0:
					switch(y) {
						case 0: break;
						case 1: { const uint8_t a = A, f = F; A = A2; F = F2; A2 = a; F2 = f; break; }
						case 2: {
							const int8_t d = int8_t(fetch());
							B = uint8_t(B - 1);
							if(B) { PC = uint16_t(PC + d); t_ += 5; }
							t_ += 4; break;
						}
						case 3: { const int8_t d = int8_t(fetch()); PC = uint16_t(PC + d); t_ += 8; break; }
						default: {
							const int8_t d = int8_t(fetch());
							if(cond(y - 4)) { PC = uint16_t(PC + d); t_ += 5; }
							t_ += 3; break;
						}
					}
					break;
				case 1:
					if(q == 0) { set_rp(p, pfx, fetch16()); t_ += 6; }
					else { const uint16_t r = add16(get_rp(2, pfx), get_rp(p, pfx)); set_rp(2, pfx, r); t_ += 7; }
					break;
				case 2:
					switch(p) {
						case 0: if(q == 0) wr(BC(), A); else A = rd(BC()); t_ += 3; break;
						case 1: if(q == 0) wr(DE(), A); else A = rd(DE()); t_ += 3; break;
						case 2: {
							const uint16_t a = fetch16();
							if(q == 0) wr16(a, get_rp(2, pfx)); else set_rp(2, pfx, rd16(a));
							t_ += 12; break;
						}
						default: {
							const uint16_t a = fetch16();
							if(q == 0) wr(a, A); else A = rd(a);
							t_ += 9; break;
						}
					}
					break;
				case 3:
					set_rp(p, pfx, uint16_t(get_rp(p, pfx) + (q == 0 ? 1 : -1)));
					t_ += 2; break;
				case 4: case 5: {
					const bool mem = y == 6;
					const uint16_t a = mem ? mem_addr() : 0;
					const uint8_t v = get_r(y, pfx, a);
					set_r(y, pfx, a, z == 4 ? inc8(v) : dec8(v));
					if(mem) t_ += 7;
					break;
				}
				case 6: {
					const bool mem = y == 6;
					const uint16_t a = mem ? mem_addr() : 0;
					const uint8_t n = fetch();
					set_r(y, pfx, a, n);
					t_ += mem ? 6 : 3;
					break;
				}
				default:
					switch(y) {
						case 0: A = uint8_t(A << 1 | A >> 7); F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | (A & 1)); break;
						case 1: { const uint8_t c = A & 1; A = uint8_t(A >> 1 | c << 7); F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | c); break; }
						case 2: { const uint8_t c = A >> 7; A = uint8_t(A << 1 | (F & fC)); F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | c); break; }
						case 3: { const uint8_t c = A & 1; A = uint8_t(A >> 1 | (F & fC) << 7); F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | c); break; }
						case 4: daa(); break;
						case 5: A = uint8_t(~A); F = uint8_t((F & (fS | fZ | fP | fC)) | (A & (fY | fX)) | fH | fN); break;
						case 6: F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | fC); break;
						default: F = uint8_t((F & (fS | fZ | fP)) | (A & (fY | fX)) | ((F & fC) ? fH : fC)); break;
					}
			}
			break;

		case 1:
			if(y == 6 && z == 6) { halted = true; break; }
			if(y == 6 || z == 6) {
				const uint16_t a = mem_addr();
				if(y == 6) wr(a, get_r(z, 0, 0)); else set_r(y, 0, 0, rd(a));
				t_ += 3;
			} else {
				set_r(y, pfx, 0, get_r(z, pfx, 0));
			}
			break;

		case 2: {
			const bool mem = z == 6;
			const uint16_t a = mem ? mem_addr() : 0;
			A = alu(y, A, get_r(z, pfx, a));
			if(mem) t_ += 3;
			break;
		}

		default:
			switch(z) {
				case 0: if(cond(y)) { PC = pop(); t_ += 6; } t_ += 1; break;
				case 1:
					if(q == 0) { set_rp2(p, pfx, pop()); t_ += 6; }
					else switch(p) {
						case 0: PC = pop(); t_ += 6; break;
						case 1: {
							uint8_t t;
							t = B; B = B2; B2 = t; t = C; C = C2; C2 = t;
							t = D; D = D2; D2 = t; t = E; E = E2; E2 = t;
							t = H; H = H2; H2 = t; t = L; L = L2; L2 = t;
							break;
						}
						case 2: PC = get_rp(2, pfx); break;
						default: SP = get_rp(2, pfx); t_ += 2; break;
					}
					break;
				case 2: { const uint16_t a = fetch16(); if(cond(y)) PC = a; t_ += 6; break; }
				case 3:
					switch(y) {
						case 0: PC = fetch16(); t_ += 6; break;
						case 1: {
							if(pfx) {
								const int8_t d = int8_t(fetch());
								exec_cb(pfx, uint16_t(ixr + d), true);
							} else exec_cb(0, 0, false);
							break;
						}
						case 2: { const uint8_t n = fetch(); bus_.out(uint16_t(A << 8 | n), A); t_ += 7; break; }
						case 3: { const uint8_t n = fetch(); A = bus_.in(uint16_t(A << 8 | n)); t_ += 7; break; }
						case 4: {
							const uint16_t t = rd16(SP);
							wr16(SP, get_rp(2, pfx));
							set_rp(2, pfx, t);
							t_ += 15; break;
						}
						case 5: { const uint16_t t = DE(); setDE(HL()); setHL(t); break; }
						case 6: IFF1 = IFF2 = false; break;
						default: IFF1 = IFF2 = true; ei_delay_ = true; break;
					}
					break;
				case 4: { const uint16_t a = fetch16(); if(cond(y)) { push(PC); PC = a; t_ += 7; } t_ += 6; break; }
				case 5:
					if(q == 0) { push(get_rp2(p, pfx)); t_ += 7; }
					else if(p == 0) { const uint16_t a = fetch16(); push(PC); PC = a; t_ += 13; }
					else if(p == 2) exec_ed();
					break;
				case 6: A = alu(y, A, fetch()); t_ += 3; break;
				default: push(PC); PC = uint16_t(y * 8); t_ += 7; break;
			}
	}
	return t_;
}

}	// namespace nx
