#include "next_machine.h"
#include "../zx_debug.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace nx {

namespace {

constexpr int kLinesPerFrame = 312;
constexpr int kTicksPerLine = 1792;	// 224 T-states a 3,5 MHz = 1792 ciclos de 28 MHz
constexpr int kUlaIntLine = 248;	// 64 líneas antes de la primera línea de papel
constexpr double kLineSeconds = 1792.0 / 28000000.0;

// Fuentes de interrupción (prioridad = número; el vector del modo IM2 por hardware es base | n << 1).
constexpr int kIntLine = 0;
constexpr int kIntUla = 11;

const float kAyVolume[16] = {
	0.0f, 0.0137f, 0.0205f, 0.0291f, 0.0423f, 0.0618f, 0.0847f, 0.1369f,
	0.1691f, 0.2647f, 0.3527f, 0.4499f, 0.5704f, 0.6873f, 0.8482f, 1.0f,
};

inline uint16_t be16(const uint8_t *p) { return uint16_t(p[0] << 8 | p[1]); }

// Paleta ULA por omisión (RRRGGGBB) de los 16 colores normales y brillantes.
const uint8_t kUlaDefault[16] = {
	0x00, 0x02, 0xA0, 0xA2, 0x14, 0x16, 0xB4, 0xB6,
	0x00, 0x03, 0xE0, 0xE7, 0x1C, 0x1F, 0xFC, 0xFF,
};

inline uint16_t c8_to_c9(uint8_t v) { return uint16_t((v << 1) | ((v >> 1) & 1) | (v & 1)); }

inline uint32_t c9_to_rgba(uint16_t c) {
	auto ex = [](int v) { return uint32_t((v << 5) | (v << 2) | (v >> 1)); };
	const uint32_t r = ex((c >> 6) & 7), g = ex((c >> 3) & 7), b = ex(c & 7);
	return 0xFF000000u | (b << 16) | (g << 8) | r;	// bytes en memoria: R,G,B,A
}

}	// namespace

// ---------------------------------------------------------------------------
// AY

void Ay::reset() {
	std::memset(reg, 0, sizeof(reg));
	selected = 0;
	for(int i = 0; i < 3; ++i) { tone_cnt[i] = 0; tone_out[i] = 1; }
	noise_cnt = 0;
	lfsr = 1;
	noise_out = 1;
	env_cnt = 0;
	env_pos = 0;
	env_holding = false;
	env_vol = 0;
	step_acc = 0.0;
}

void Ay::write_reg(uint8_t r, uint8_t v) {
	r &= 15;
	reg[r] = v;
	if(r == 13) {
		const bool attack = v & 4;
		env_vol = attack ? 0 : 15;
		env_pos = attack ? 1 : 0;	// env_pos = 1 → subiendo
		env_holding = false;
		env_cnt = 0;
	}
}

void Ay::tick() {
	for(int c = 0; c < 3; ++c) {
		int period = reg[c * 2] | ((reg[c * 2 + 1] & 0x0F) << 8);
		if(period < 1) period = 1;
		if(++tone_cnt[c] >= period) { tone_cnt[c] = 0; tone_out[c] ^= 1; }
	}
	int np = reg[6] & 0x1F;
	if(np < 1) np = 1;
	if(++noise_cnt >= np) {
		noise_cnt = 0;
		const uint32_t bit = (lfsr ^ (lfsr >> 3)) & 1;
		lfsr = (lfsr >> 1) | (bit << 16);
		noise_out = lfsr & 1;
	}
	int ep = reg[11] | (reg[12] << 8);
	if(ep < 1) ep = 1;
	if(++env_cnt >= ep) {
		env_cnt = 0;
		if(env_holding) return;
		const uint8_t shape = reg[13] & 15;
		const bool up = env_pos == 1;
		bool end_ramp = false;
		if(up) { if(env_vol < 15) ++env_vol; else end_ramp = true; }
		else { if(env_vol > 0) --env_vol; else end_ramp = true; }
		if(end_ramp) {
			const bool cont = shape & 8, alt = shape & 2, hold = shape & 1;
			if(!cont) { env_holding = true; env_vol = 0; }
			else if(hold) {
				env_holding = true;
				env_vol = alt ? (up ? 0 : 15) : (up ? 15 : 0);
			} else if(alt) env_pos = up ? 0 : 1;
			else env_vol = up ? 0 : 15;
		}
	}
}

void Ay::levels(float &a, float &b, float &c) const {
	float out[3];
	for(int ch = 0; ch < 3; ++ch) {
		const bool tone_dis = reg[7] & (1 << ch), noise_dis = reg[7] & (8 << ch);
		const bool on = (tone_out[ch] || tone_dis) && (noise_out || noise_dis);
		const int vol = (reg[8 + ch] & 0x10) ? env_vol : (reg[8 + ch] & 0x0F);
		out[ch] = on ? kAyVolume[vol] : 0.0f;
	}
	a = out[0]; b = out[1]; c = out[2];
}

// ---------------------------------------------------------------------------
// Máquina

NextMachine::NextMachine(int audio_rate)
	: cpu_(*this), ram_(0x200000), audio_rate_(audio_rate) {
	std::memset(rom_, 0xFF, sizeof(rom_));
	back_.assign(size_t(kFbWidth) * kFbHeight * 4, 0);
	front_ = back_;
	reset();
}

NextMachine::~NextMachine() {
	for(FILE *f : esx_files_) if(f) std::fclose(f);
}

// Devuelve los ticks de 28 MHz usados, o -1 si el depurador detuvo la CPU ANTES de ejecutar
// la instrucción (punto de parada, paso, pausa…). Un watchpoint deja terminar la instrucción.
int NextMachine::cpu_step() {
	const bool dbg = dbg_ && zxdbg::g.armed;
	if(dbg) {
		zxdbg::Core &c = zxdbg::g;
		dbg_watch_ = c.watch_any;
		if(dbg_skip_) dbg_skip_ = false;	// primera instrucción tras reanudar una parada en el fetch
		else {
			uint16_t pc = cpu_.PC;
			uint8_t op;
			if(cpu_.halted) { pc = uint16_t(pc - 1); op = 0x76; }	// HALT ya ejecutado: PC apunta a la siguiente
			else op = peek(pc);
			c.prefix = 0;	// on_fetch recibe solo inicios de instrucción
			if(zxdbg::on_fetch(pc, op)) { dbg_skip_ = true; return -1; }
		}
	} else dbg_watch_ = false;

	int cost;
	if(cpu_.PC == 0x0008 && mmu_[0] == 0xFF) {
		esx_call();
		cost = 10 * ticks_per_t();
	} else {
		++instr_count_;
		cost = cpu_.step() * ticks_per_t();
	}
	if(dbg) {
		zxdbg::Core &c = zxdbg::g;
		dbg_ticks_ += uint64_t(cost);
		c.clock = int64_t(dbg_ticks_ >> 2);	// half cycles de 3,5 MHz
		if(c.stopped) {	// watchpoint: registros con la instrucción ya terminada
			c.t.regs(c.t.ctx, &c.regs);
			c.regs.pc = c.stop_pc;
		}
	}
	return cost;
}

void NextMachine::watch_hit(uint16_t addr, uint8_t val, bool write) {
	zxdbg::on_mem(addr, val, write);
}

void NextMachine::attach_debugger() {
	using namespace zxdbg;
	Target t;
	t.ctx = this;
	t.regs = [](void *p, Regs *r) {
		const Z80N &z = static_cast<NextMachine *>(p)->cpu_;
		r->pc = z.PC; r->sp = z.SP;
		r->af = uint16_t(z.A << 8 | z.F); r->bc = z.BC(); r->de = z.DE(); r->hl = z.HL();
		r->af2 = uint16_t(z.A2 << 8 | z.F2); r->bc2 = uint16_t(z.B2 << 8 | z.C2);
		r->de2 = uint16_t(z.D2 << 8 | z.E2); r->hl2 = uint16_t(z.H2 << 8 | z.L2);
		r->ix = z.IX; r->iy = z.IY; r->memptr = 0;
		r->i = z.I; r->r = z.R; r->iff1 = z.IFF1; r->iff2 = z.IFF2; r->im = z.IM;
	};
	t.peek = [](void *p, uint16_t a) { return static_cast<NextMachine *>(p)->peek(a); };
	t.poke = [](void *p, uint16_t a, uint8_t v) {
		NextMachine *m = static_cast<NextMachine *>(p);
		if(uint8_t *w = m->wrp_[a >> 13]) w[a & 0x1FFF] = v;
	};
	t.credit = [](void *, int64_t) {};	// la Next para entre instrucciones: no hay deuda de ciclos
	t.peek_bank = [](void *p, int kind, int bank, uint16_t off) { return static_cast<NextMachine *>(p)->peek_bank16(kind == 1, bank, off); };
	t.poke_bank = [](void *p, int kind, int bank, uint16_t off, uint8_t v) { if(kind == 0) static_cast<NextMachine *>(p)->poke_bank16(bank, off, v); };
	t.paging = [](void *p, uint8_t *p7, uint8_t *p1) { *p7 = static_cast<NextMachine *>(p)->port_7ffd_; *p1 = 0; };
	t.peek_page = [](void *p, int page, uint16_t off) { return static_cast<NextMachine *>(p)->peek_page(page, off); };
	t.poke_page = [](void *p, int page, uint16_t off, uint8_t v) { static_cast<NextMachine *>(p)->poke_page(page, off, v); };
	t.mmu = [](void *p, uint8_t out[8]) { for(int i = 0; i < 8; ++i) out[i] = static_cast<NextMachine *>(p)->mmu_[i]; };
	t.nextreg = [](void *p, uint8_t r) { return static_cast<NextMachine *>(p)->nr_[r]; };
	t.cpu_speed = [](void *p) { return static_cast<NextMachine *>(p)->cpu_speed_; };
	t.frame_half_cycles = int64_t(kLinesPerFrame) * kTicksPerLine / 4;
	Core &c = g;
	c.t = t;
	c.stopped = false;
	c.event_pending = false;
	c.debt = 0;
	c.prefix = 0;
	c.last_start_pc = -1;
	c.next_frame = 0;
	dbg_ = true;
	dbg_skip_ = false;
	dbg_ticks_ = 0;
}

void NextMachine::detach_debugger() {
	dbg_ = dbg_watch_ = dbg_skip_ = false;
	zxdbg::detach(this);
}

bool NextMachine::set_rom(const uint8_t *data, size_t size) {
	if(size < 0x4000) return false;
	std::memcpy(rom_, data, 0x4000);
	remap();
	return true;
}

void NextMachine::set_defaults() {
	std::memset(nr_, 0, sizeof(nr_));
	nr_[0x00] = 0x0A;
	nr_[0x08] = 0x1A;	// altavoz, DAC y TurboSound activados
	nr_[0x12] = 9;
	nr_[0x13] = 12;
	nr_[0x14] = 0xE3;
	nr_[0x42] = 0x07;
	nr_[0x4A] = 0xE3;
	nr_[0x4B] = 0xE3;
	nr_[0x4C] = 0x0F;
	nr_[0x6E] = 0x2C;
	nr_[0x6F] = 0x0C;
	nr_[0xC4] = 0x01;
	const uint8_t full[4] = {0, 255, 0, 191};
	std::memcpy(clip_l2_, full, 4);
	std::memcpy(clip_spr_, full, 4);
	std::memcpy(clip_ula_, full, 4);
	const uint8_t tfull[4] = {0, 159, 0, 255};
	std::memcpy(clip_tile_, tfull, 4);
	std::memset(clip_idx_, 0, sizeof(clip_idx_));
}

void NextMachine::reset() {
	for(FILE *&f : esx_files_) { if(f) std::fclose(f); f = nullptr; }
	std::fill(ram_.begin(), ram_.end(), 0);
	set_defaults();
	for(int k = 0; k < 8; ++k)
		for(int i = 0; i < 256; ++i) {
			const uint16_t c = (k < 2) ? c8_to_c9(kUlaDefault[i & 15]) : c8_to_c9(uint8_t(i));
			pal9_[k][i] = c;
			rgba_[k][i] = c9_to_rgba(c);
		}
	std::memset(l2_prio_, 0, sizeof(l2_prio_));
	pal_index_ = 0;
	pal_sub_ = 0;

	mmu_[0] = mmu_[1] = 0xFF;
	mmu_[2] = 10; mmu_[3] = 11;	// banco 5
	mmu_[4] = 4; mmu_[5] = 5;	// banco 2
	mmu_[6] = 0; mmu_[7] = 1;	// banco 0
	port_7ffd_ = 0;
	port_dffd_ = 0;
	l2_wr_en_ = l2_rd_en_ = l2_shadow_map_ = l2_enable_ = false;
	l2_segment_ = 0;
	remap();

	std::memset(spr_pat_, 0, sizeof(spr_pat_));
	std::memset(spr_attr_, 0, sizeof(spr_attr_));
	spr_attr_idx_ = spr_pat_idx_ = mirror_sprite_ = 0;
	sprites_dirty_ = true;

	std::memset(copper_ram_, 0, sizeof(copper_ram_));
	copper_addr_ = 0;
	copper_mode_ = 0;
	copper_pc_ = 0;

	dma_ = Dma();
	cpu_speed_ = 0;
	int_hw_mode_ = false;
	int_pulse_ticks_ = 0;
	int_pending_ = int_service_ = 0;

	cvc_ = 0;
	frame_counter_ = 0;
	border_ = 0;
	port_ff_ = 0;
	std::memset(key_rows_, 0, sizeof(key_rows_));
	joy_ = 0;
	for(auto &a : ay_) a.reset();
	ay_selected_ = 0;
	for(auto &d : dac_) d = 0x80;
	beeper_ = false;
	audio_.clear();
	audio_read_ = 0;
	audio_acc_ = 0;
	pending_ = 0;
	budget_ = 0;
	line_started_ = false;
	dbg_skip_ = false;
	emulated_ = 0;
	instr_count_ = 0;
	completed_frames_ = 0;
	cpu_.reset();
	cpu_.IM = 1;
}

void NextMachine::remap() {
	for(int s = 0; s < 8; ++s) {
		const uint8_t p = mmu_[s];
		if(p == 0xFF) {
			rdp_[s] = rom_ + ((s & 1) ? 0x2000 : 0);
			wrp_[s] = nullptr;
		} else {
			rdp_[s] = page(p);
			wrp_[s] = page(p);
		}
	}
	if(l2_wr_en_ || l2_rd_en_) {
		const int bank = (l2_shadow_map_ ? nr_[0x13] : nr_[0x12]) & 0x7F;
		auto set_seg = [&](int slot, int b) {
			if(l2_wr_en_) wrp_[slot] = bank16(b);
			if(l2_rd_en_) rdp_[slot] = bank16(b);
		};
		if(l2_segment_ == 3) {
			for(int seg = 0; seg < 3; ++seg) {
				set_seg(seg * 2, bank + seg);
				if(l2_wr_en_) wrp_[seg * 2 + 1] = bank16(bank + seg) + 0x2000;
				if(l2_rd_en_) rdp_[seg * 2 + 1] = bank16(bank + seg) + 0x2000;
			}
		} else {
			set_seg(0, bank + l2_segment_);
			if(l2_wr_en_) wrp_[1] = bank16(bank + l2_segment_) + 0x2000;
			if(l2_rd_en_) rdp_[1] = bank16(bank + l2_segment_) + 0x2000;
		}
	}
}

// ---------------------------------------------------------------------------
// Puertos

uint8_t NextMachine::kempston() const {
	uint8_t v = 0;
	if(joy_ & 0x08) v |= 0x01;	// derecha
	if(joy_ & 0x04) v |= 0x02;	// izquierda
	if(joy_ & 0x02) v |= 0x04;	// abajo
	if(joy_ & 0x01) v |= 0x08;	// arriba
	if(joy_ & 0x10) v |= 0x10;	// fuego
	return v;
}

uint8_t NextMachine::in(uint16_t port) {
	const uint8_t lo = uint8_t(port);
	if(!(port & 1)) {
		uint8_t r = 0x1F;
		for(int row = 0; row < 8; ++row)
			if(!(port & (0x100 << row))) r &= uint8_t(~key_rows_[row]);
		return uint8_t(r | 0xA0);
	}
	{
		uint8_t mv;
		if(mouse_.read(port, mv)) return mv;
	}
	if((port & 0xC007) == 0xC005) {
		const int chip = (nr_[0x08] & 0x02) ? ay_selected_ : 0;
		return ay_[chip].reg[ay_[chip].selected & 15];
	}
	switch(port) {
		case 0x243B: return nr_select_;
		case 0x253B: return nr_read(nr_select_);
		case 0x123B:
			return uint8_t((l2_segment_ << 6) | (l2_shadow_map_ << 3) | (l2_rd_en_ << 2) | (l2_enable_ << 1) | l2_wr_en_);
		case 0x303B: return 0;
		default: break;
	}
	switch(lo) {
		case 0x1F: return kempston();
		case 0x37: return 0;
		case 0x6B: return dma_read();
		case 0x0B: return dma_read();
		case 0xFF: return 0xFF;
		default: break;
	}
	return 0xFF;
}

void NextMachine::out(uint16_t port, uint8_t v) {
	const uint8_t lo = uint8_t(port);
	if(!(port & 1)) {
		border_ = v & 7;
		beeper_ = (v & 0x10) != 0;
		return;
	}
	if((port & 0xC007) == 0xC005) {	// $FFFD
		if((nr_[0x08] & 0x02) && (v & 0x9C) == 0x9C) ay_selected_ = 3 - (v & 3);
		else ay_[(nr_[0x08] & 0x02) ? std::min(ay_selected_, 2) : 0].selected = v & 15;
		if(ay_selected_ > 2) ay_selected_ = 2;
		return;
	}
	if((port & 0xC007) == 0x8005) {	// $BFFD
		const int chip = (nr_[0x08] & 0x02) ? std::min(ay_selected_, 2) : 0;
		ay_[chip].write_reg(ay_[chip].selected, v);
		return;
	}
	if((port & 0x8003) == 0x0001) {	// $7FFD
		port_7ffd_ = v;
		const int bank = (v & 7) | ((port_dffd_ & 0x0F) << 3);
		mmu_[6] = uint8_t(bank * 2);
		mmu_[7] = uint8_t(bank * 2 + 1);
		remap();
		return;
	}
	if((port & 0xF003) == 0xD001) {	// $DFFD
		port_dffd_ = v;
		const int bank = (port_7ffd_ & 7) | ((v & 0x0F) << 3);
		mmu_[6] = uint8_t(bank * 2);
		mmu_[7] = uint8_t(bank * 2 + 1);
		remap();
		return;
	}
	switch(port) {
		case 0x243B: nr_select_ = v; return;
		case 0x253B: nr_write(nr_select_, v); return;
		case 0x123B:
			if(!(v & 0x10)) {
				l2_enable_ = v & 2;
				l2_wr_en_ = v & 1;
				l2_rd_en_ = v & 4;
				l2_shadow_map_ = v & 8;
				l2_segment_ = v >> 6;
				remap();
			}
			return;
		case 0x303B:
			spr_pat_idx_ = ((v & 0x3F) << 8) | (v & 0x80);
			spr_attr_idx_ = (v & 0x7F) << 3;
			return;
		default: break;
	}
	const bool dac_en = nr_[0x08] & 0x08;
	switch(lo) {
		case 0xFF: port_ff_ = v; return;
		case 0x57: {
			spr_attr_[spr_attr_idx_ >> 3][spr_attr_idx_ & 7] = v;
			sprites_dirty_ = true;
			const bool next_sprite = (spr_attr_idx_ & 4) || ((spr_attr_idx_ & 7) == 3 && !(v & 0x40));
			if(next_sprite) spr_attr_idx_ = (((spr_attr_idx_ >> 3) + 1) & 0x7F) << 3;
			else spr_attr_idx_ = (spr_attr_idx_ + 1) & 0x3FF;
			return;
		}
		case 0x5B:
			spr_pat_[spr_pat_idx_] = v;
			spr_pat_idx_ = (spr_pat_idx_ + 1) & 0x3FFF;
			return;
		case 0x6B: dma_write(v, false); return;
		case 0x0B: dma_write(v, true); return;
		case 0x0F: if(dac_en) dac_[1] = v; return;
		case 0x4F: if(dac_en) dac_[2] = v; return;
		case 0x5F: if(dac_en) dac_[3] = v; return;
		case 0xB3: if(dac_en) dac_[1] = dac_[2] = v; return;
		case 0xDF: if(dac_en) dac_[0] = dac_[3] = v; return;
		case 0xF1: if(dac_en) dac_[0] = v; return;
		case 0xF3: if(dac_en) dac_[1] = v; return;
		case 0xF9: if(dac_en) dac_[2] = v; return;
		case 0xFB: if(dac_en) dac_[0] = dac_[3] = v; return;
		default: break;
	}
}

// ---------------------------------------------------------------------------
// NextRegs

uint8_t NextMachine::nr_read(uint8_t r) {
	switch(r) {
		case 0x01: return 0x32;
		case 0x0E: return 0x04;
		case 0x0F: return 0x00;
		case 0x07: return uint8_t(cpu_speed_ | (cpu_speed_ << 4));
		case 0x1C:
			return uint8_t((clip_idx_[3] << 6) | (clip_idx_[2] << 4) | (clip_idx_[1] << 2) | clip_idx_[0]);
		case 0x1E: return uint8_t((cvc_ >> 8) & 1);
		case 0x1F: return uint8_t(cvc_);
		case 0x41: return uint8_t(pal9_[0][0] >> 1);	// aproximación
		case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
			return mmu_[r - 0x50];
		case 0xC8: return uint8_t(((int_service_ >> kIntLine) & 1) << 1 | ((int_service_ >> kIntUla) & 1));
		default: return nr_[r];
	}
}

void NextMachine::pal_set(int kind, int idx, uint16_t c9, bool prio) {
	pal9_[kind][idx] = c9;
	rgba_[kind][idx] = c9_to_rgba(c9);
	if((kind == 2 || kind == 3)) l2_prio_[kind - 2][idx] = prio;
}

void NextMachine::pal_write(uint16_t c9, bool prio) {
	const uint8_t sel = (nr_[0x43] >> 4) & 7;
	const int kind = (sel & 3) * 2 + (sel >> 2);
	pal_set(kind, pal_index_, c9, prio);
}

void NextMachine::nr_write(uint8_t reg, uint8_t v) {
	if(trace_regs) std::fprintf(stderr, "NR %02X <= %02X  (PC=%04X)\n", reg, v, cpu_.PC);
	nr_[reg] = v;
	switch(reg) {
		case 0x07:
			cpu_speed_ = v & 3;
			break;
		case 0x12: case 0x13:
			remap();
			break;
		case 0x18: case 0x19: case 0x1A: case 0x1B: {
			uint8_t *clip = reg == 0x18 ? clip_l2_ : reg == 0x19 ? clip_spr_ : reg == 0x1A ? clip_ula_ : clip_tile_;
			uint8_t &idx = clip_idx_[reg - 0x18];
			clip[idx] = v;
			idx = (idx + 1) & 3;
			break;
		}
		case 0x1C:
			for(int i = 0; i < 4; ++i) if(v & (1 << i)) clip_idx_[i] = 0;
			break;
		case 0x2C: dac_[1] = v; break;
		case 0x2D: dac_[0] = dac_[3] = v; break;
		case 0x2E: dac_[2] = v; break;
		case 0x34:
			mirror_sprite_ = v & 0x7F;
			break;
		case 0x35: case 0x36: case 0x37: case 0x38: case 0x39:
		case 0x75: case 0x76: case 0x77: case 0x78: case 0x79: {
			spr_attr_[mirror_sprite_][(reg & 0x3F) - 0x35] = v;
			sprites_dirty_ = true;
			if(reg >= 0x75) mirror_sprite_ = (mirror_sprite_ + 1) & 0x7F;
			break;
		}
		case 0x40:
			pal_index_ = v;
			pal_sub_ = 0;
			break;
		case 0x41:
			pal_write(c8_to_c9(v), false);
			if(!(nr_[0x43] & 0x80)) ++pal_index_;
			pal_sub_ = 0;
			break;
		case 0x43:
			pal_sub_ = 0;
			break;
		case 0x44:
			if(pal_sub_ == 0) pal_stored_ = v;
			else {
				pal_write(uint16_t((pal_stored_ << 1) | (v & 1)), (v & 0x80) != 0);
				if(!(nr_[0x43] & 0x80)) ++pal_index_;
			}
			pal_sub_ ^= 1;
			break;
		case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
			mmu_[reg - 0x50] = v;
			remap();
			break;
		case 0x60: case 0x63: {
			if((copper_addr_ & 1) == 0) {
				if(reg == 0x60) copper_ram_[copper_addr_] = v;
				copper_store_ = v;
			} else {
				if(reg == 0x63) copper_ram_[copper_addr_ & ~1] = copper_store_;
				copper_ram_[copper_addr_] = v;
			}
			copper_addr_ = (copper_addr_ + 1) & 0x7FF;
			break;
		}
		case 0x61:
			copper_addr_ = (copper_addr_ & 0x700) | v;
			break;
		case 0x62: {
			const int mode = (v >> 6) & 3;
			copper_addr_ = (copper_addr_ & 0xFF) | ((v & 7) << 8);
			if(mode != copper_mode_) {
				copper_mode_ = mode;
				if(mode == 1 || mode == 3) copper_pc_ = 0;
			}
			break;
		}
		case 0x69:
			port_ff_ = uint8_t((port_ff_ & 0xC0) | (v & 0x3F));
			port_7ffd_ = uint8_t((port_7ffd_ & ~0x08) | ((v & 0x40) ? 0x08 : 0));
			l2_enable_ = v & 0x80;
			break;
		case 0xC0:
			int_hw_mode_ = v & 1;
			break;
		default: break;
	}
}

// ---------------------------------------------------------------------------
// DMA

void NextMachine::dma_write(uint8_t d, bool zilog) {
	Dma &m = dma_;
	m.zilog = zilog;
	if(m.follow_pos < m.nfollow) {
		const int code = m.follow[m.follow_pos++];
		switch(code) {
			case 0: m.a_start = uint16_t((m.a_start & 0xFF00) | d); break;
			case 1: m.a_start = uint16_t((m.a_start & 0x00FF) | (d << 8)); break;
			case 2: m.len = uint16_t((m.len & 0xFF00) | d); break;
			case 3: m.len = uint16_t((m.len & 0x00FF) | (d << 8)); break;
			case 4:	// temporización del puerto A
				m.a_cyc = 4 - (d & 3);
				if(m.a_cyc < 2) m.a_cyc = 2;
				break;
			case 5:	// temporización del puerto B
				m.b_cyc = 4 - (d & 3);
				if(m.b_cyc < 2) m.b_cyc = 2;
				if(d & 0x20) { m.follow[m.nfollow++] = 6; }
				break;
			case 6: m.prescaler = d; break;
			case 7: m.b_start = uint16_t((m.b_start & 0xFF00) | d); break;
			case 8: m.b_start = uint16_t((m.b_start & 0x00FF) | (d << 8)); break;
			case 9: break;	// control de interrupciones (ignorado)
			case 10: m.read_mask = d & 0x7F; m.read_pos = 0; break;
			default: break;
		}
		if(m.follow_pos >= m.nfollow) m.nfollow = m.follow_pos = 0;
		return;
	}
	m.nfollow = m.follow_pos = 0;
	auto add = [&](int c) { m.follow[m.nfollow++] = c; };
	if(!(d & 0x80)) {
		if(d & 3) {	// WR0
			m.a_to_b = d & 0x04;
			if(d & 0x08) add(0);
			if(d & 0x10) add(1);
			if(d & 0x20) add(2);
			if(d & 0x40) add(3);
		} else if((d & 7) == 4) {	// WR1
			m.a_io = d & 0x08;
			const int am = (d >> 4) & 3;
			m.a_mode = am == 0 ? 0 : am == 1 ? 1 : 2;
			if(d & 0x40) add(4);
		} else {	// WR2
			m.b_io = d & 0x08;
			const int bm = (d >> 4) & 3;
			m.b_mode = bm == 0 ? 0 : bm == 1 ? 1 : 2;
			if(d & 0x40) add(5);
		}
	} else {
		switch(d & 3) {
			case 0: break;	// WR3
			case 1:	// WR4
				m.mode = (d >> 5) & 3;
				if(d & 0x04) add(7);
				if(d & 0x08) add(8);
				if(d & 0x10) add(9);
				break;
			case 2:	// WR5
				m.autorestart = d & 0x20;
				break;
			default: dma_command(d); break;
		}
	}
}

void NextMachine::dma_command(uint8_t c) {
	Dma &m = dma_;
	switch(c) {
		case 0xC3:	// reset
			m.enabled = false;
			m.autorestart = false;
			m.prescaler = 0;
			m.a_cyc = m.b_cyc = 2;
			break;
		case 0xC7: m.a_cyc = 2; break;
		case 0xCB: m.b_cyc = 2; m.prescaler = 0; break;
		case 0xCF:	// load
			m.a_ptr = m.a_start;
			m.b_ptr = m.b_start;
			m.counter = 0;
			m.transferred = false;
			break;
		case 0xD3:	// continue
			m.counter = 0;
			break;
		case 0x87:	// enable
			m.enabled = true;
			m.next_ok = 0;
			break;
		case 0x83: m.enabled = false; break;
		case 0xBB:
			m.follow[m.nfollow++] = 10;
			break;
		case 0xBF: case 0xA7: m.read_pos = 0; break;
		default: break;
	}
}

uint8_t NextMachine::dma_read() {
	Dma &m = dma_;
	// Secuencia: estado, contador (lo, hi), A (lo, hi), B (lo, hi), filtrada por la máscara.
	for(int guard = 0; guard < 8; ++guard) {
		const int pos = m.read_pos;
		m.read_pos = (m.read_pos + 1) % 7;
		if(!(m.read_mask & (1 << pos))) continue;
		switch(pos) {
			case 0: {
				const int total = m.zilog ? m.len + 1 : m.len;
				const bool ended = m.counter >= total;
				return uint8_t(0x38 | (ended ? 0 : 2) | (m.transferred ? 1 : 0));
			}
			case 1: return uint8_t(m.counter);
			case 2: return uint8_t(m.counter >> 8);
			case 3: return uint8_t(m.a_ptr);
			case 4: return uint8_t(m.a_ptr >> 8);
			case 5: return uint8_t(m.b_ptr);
			default: return uint8_t(m.b_ptr >> 8);
		}
	}
	return 0xFF;
}

int NextMachine::dma_transfer_byte() {
	Dma &m = dma_;
	uint16_t &src = m.a_to_b ? m.a_ptr : m.b_ptr;
	uint16_t &dst = m.a_to_b ? m.b_ptr : m.a_ptr;
	const bool src_io = m.a_to_b ? m.a_io : m.b_io;
	const bool dst_io = m.a_to_b ? m.b_io : m.a_io;
	const int src_mode = m.a_to_b ? m.a_mode : m.b_mode;
	const int dst_mode = m.a_to_b ? m.b_mode : m.a_mode;

	const uint8_t v = src_io ? in(src) : read(src);
	if(dst_io) out(dst, v); else write(dst, v);
	if(src_mode == 1) ++src; else if(src_mode == 0) --src;
	if(dst_mode == 1) ++dst; else if(dst_mode == 0) --dst;
	++m.counter;
	m.transferred = true;
	const int total = m.zilog ? m.len + 1 : m.len;
	if(m.counter >= total) {
		if(m.autorestart) {
			m.a_ptr = m.a_start;
			m.b_ptr = m.b_start;
			m.counter = 0;
		} else m.enabled = false;
	}
	return (m.a_cyc + m.b_cyc) * ticks_per_t();
}

// ---------------------------------------------------------------------------
// Interrupciones

void NextMachine::raise_int(int source) {
	if(int_hw_mode_) {
		int_pending_ |= uint16_t(1 << source);
	} else {
		int_pulse_ticks_ = 32 * ticks_per_t();
	}
	update_int_line();
}

void NextMachine::update_int_line() {
	if(int_hw_mode_) cpu_.int_line = (int_pending_ & ~int_service_) != 0 && int_pending_ != 0;
	else cpu_.int_line = int_pulse_ticks_ > 0;
}

uint8_t NextMachine::int_vector() {
	if(!int_hw_mode_) return 0xFF;
	const uint8_t base = uint8_t(nr_[0xC0] & 0xE0);
	for(int s = 0; s < 16; ++s) {
		if((int_pending_ & (1 << s)) && !(int_service_ & (1 << s))) {
			int_pending_ &= uint16_t(~(1 << s));
			int_service_ |= uint16_t(1 << s);
			update_int_line();
			return uint8_t(base | (s << 1));
		}
	}
	return 0xFF;
}

void NextMachine::reti_executed() {
	for(int s = 0; s < 16; ++s) {
		if(int_service_ & (1 << s)) { int_service_ &= uint16_t(~(1 << s)); break; }
	}
	update_int_line();
}

// ---------------------------------------------------------------------------
// Teclado y mando

void NextMachine::set_key(int key, bool pressed) {
	const int row = (key >> 8) & 7;
	const uint8_t bit = uint8_t(key & 0xFF);
	if(pressed) key_rows_[row] |= bit; else key_rows_[row] &= uint8_t(~bit);
}

void NextMachine::clear_keys() { std::memset(key_rows_, 0, sizeof(key_rows_)); }

void NextMachine::set_joystick(int mask) { joy_ = uint8_t(mask); }

// ---------------------------------------------------------------------------
// Audio

void NextMachine::gen_audio(double seconds) {
	audio_acc_ += seconds * audio_rate_;
	const int n = int(audio_acc_);
	audio_acc_ -= n;
	constexpr double kAyStepRate = 1773447.5 / 8.0;
	const double steps_per_sample = kAyStepRate / audio_rate_;
	const bool stereo_acb = nr_[0x08] & 0x20;
	const int mono_mask = (nr_[0x09] >> 5) & 7;
	for(int i = 0; i < n; ++i) {
		float l = 0.0f, r = 0.0f;
		for(int chip = 0; chip < 3; ++chip) {
			Ay &ay = ay_[chip];
			ay.step_acc += steps_per_sample;
			float sa = 0, sb = 0, sc = 0;
			int steps = 0;
			while(ay.step_acc >= 1.0) {
				ay.step_acc -= 1.0;
				ay.tick();
				float a, b, c;
				ay.levels(a, b, c);
				sa += a; sb += b; sc += c;
				++steps;
			}
			float a, b, c;
			if(steps) { a = sa / steps; b = sb / steps; c = sc / steps; }
			else ay.levels(a, b, c);
			if(mono_mask & (1 << chip)) {
				const float m = (a + b + c) * 0.5f;
				l += m; r += m;
			} else if(stereo_acb) {
				l += a + c * 0.5f; r += b + c * 0.5f;
			} else {
				l += a + b * 0.5f; r += c + b * 0.5f;
			}
		}
		l *= 0.18f; r *= 0.18f;
		if(beeper_) { l += 0.12f; r += 0.12f; }
		if(nr_[0x08] & 0x08) {
			l += ((dac_[0] + dac_[1]) - 256) * (0.18f / 256.0f);
			r += ((dac_[2] + dac_[3]) - 256) * (0.18f / 256.0f);
		}
		auto to16 = [](float v) { return int16_t(std::clamp(v, -1.0f, 1.0f) * 30000.0f); };
		audio_.push_back(to16(l));
		audio_.push_back(to16(r));
	}
}

int NextMachine::drain_audio(int16_t *out, int max_samples) {
	const size_t avail = audio_.size() - audio_read_;
	const size_t n = std::min(avail, size_t(std::max(max_samples, 0)) & ~size_t(1));
	if(n) std::memcpy(out, audio_.data() + audio_read_, n * sizeof(int16_t));
	audio_read_ += n;
	if(audio_read_ == audio_.size()) { audio_.clear(); audio_read_ = 0; }
	else if(audio_read_ > 65536) {
		audio_.erase(audio_.begin(), audio_.begin() + audio_read_);
		audio_read_ = 0;
	}
	// Tope para no acumular si nadie consume (~1 s).
	if(audio_.size() > size_t(audio_rate_) * 4) { audio_.clear(); audio_read_ = 0; }
	return int(n);
}

// ---------------------------------------------------------------------------
// Bucle principal

bool NextMachine::run_line() {
	if(!line_started_) {	// si el depurador interrumpió la línea, al reanudar no se repiten sus eventos
		// Eventos de inicio de línea.
		if(cvc_ == kUlaIntLine && (nr_[0xC4] & 0x01)) raise_int(kIntUla);
		{
			const int line_val = ((nr_[0x22] & 1) << 8) | nr_[0x23];
			if(((nr_[0x22] & 2) || (nr_[0xC4] & 2)) && cvc_ == line_val % kLinesPerFrame) raise_int(kIntLine);
		}
		if(cvc_ == 0 && copper_mode_ == 3) copper_pc_ = 0;
		budget_ += kTicksPerLine;
		line_started_ = true;
	}

	while(budget_ > 0) {
		int cost;
		if(dma_.enabled) {
			if(dma_.next_ok <= 0) {
				cost = dma_transfer_byte();
				dma_.next_ok = dma_.prescaler ? int64_t(dma_.prescaler) * 32 - cost : 0;
				if(dma_.next_ok < 0) dma_.next_ok = 0;
			} else if(dma_.mode == 1) {
				cost = int(std::min<int64_t>(budget_, dma_.next_ok));
				if(cost < 1) cost = 1;
				dma_.next_ok -= cost;
			} else {
				cost = cpu_step();
				if(cost < 0) return false;
				dma_.next_ok -= cost;
			}
		} else {
			cost = cpu_step();
			if(cost < 0) return false;
		}
		budget_ -= cost;
		if(int_pulse_ticks_ > 0 && !int_hw_mode_) {
			int_pulse_ticks_ -= cost;
			if(int_pulse_ticks_ <= 0) { int_pulse_ticks_ = 0; update_int_line(); }
		}
		if(dbg_ && zxdbg::g.stopped) return false;	// watchpoint
	}

	line_started_ = false;
	render_line();
	gen_audio(kLineSeconds);

	if(++cvc_ >= kLinesPerFrame) cvc_ = 0;
	if(cvc_ == 224) {	// terminó la última fila visible
		front_.swap(back_);
		++completed_frames_;
		++frame_counter_;
	}
	return true;
}

int NextMachine::run(double seconds) {
	if(seconds <= 0) return 0;
	if(dbg_ && zxdbg::g.stopped) return 0;	// detenida por el depurador: el tiempo no corre
	pending_ += seconds * speed_multiplier_;
	completed_frames_ = 0;
	int guard = 0;
	while(pending_ >= kLineSeconds && guard++ < 40000) {
		if(!run_line()) break;	// parada del depurador (la línea se retoma al reanudar)
		pending_ -= kLineSeconds;
		emulated_ += kLineSeconds;
	}
	if(pending_ > 0.5) pending_ = 0;	// pausa larga: se descarta
	return completed_frames_;
}

// ---------------------------------------------------------------------------
// Cargador .nex

bool NextMachine::load_nex(const uint8_t *d, size_t n, std::string &error) {
	if(n < 512 || std::memcmp(d, "Next", 4) != 0) { error = "bad_nex"; return false; }
	reset();

	const uint8_t screen_flags = d[10];
	const uint8_t border = d[11];
	const uint16_t sp = uint16_t(d[12] | (d[13] << 8));
	const uint16_t pc = uint16_t(d[14] | (d[15] << 8));
	const uint8_t *bank_map = d + 18;
	const uint8_t entry_bank = d[139];

	size_t pos = 512;
	auto take = [&](size_t count) -> const uint8_t * {
		if(pos + count > n) return nullptr;
		const uint8_t *p = d + pos;
		pos += count;
		return p;
	};

	const bool has_palette = (screen_flags & 0x05) && !(screen_flags & 0x9A);
	if(has_palette) {
		const uint8_t *pal = take(512);
		if(!pal) { error = "bad_nex"; return false; }
		const int kind = (screen_flags & 0x01) ? 2 : 0;
		for(int i = 0; i < 256; ++i)
			pal_set(kind, i, uint16_t((pal[i * 2] << 1) | (pal[i * 2 + 1] & 1)), false);
	}
	auto load_into = [&](int bank, size_t offset, size_t count) -> bool {
		const uint8_t *p = take(count);
		if(!p) return false;
		std::memcpy(bank16(bank) + offset, p, count);
		return true;
	};
	if(screen_flags & 0x01) {
		if(!load_into(9, 0, 0x4000) || !load_into(10, 0, 0x4000) || !load_into(11, 0, 0x4000)) { error = "bad_nex"; return false; }
		nr_[0x69] |= 0x80;
		l2_enable_ = true;
	}
	if(screen_flags & 0x02) {
		if(!load_into(5, 0, 0x1B00)) { error = "bad_nex"; return false; }
	}
	for(uint8_t mask = 0x04; mask <= 0x10; mask <<= 1) {
		if(screen_flags & mask) {
			if(!load_into(5, 0, 0x1800) || !load_into(5, 0x2000, 0x1800)) { error = "bad_nex"; return false; }
			if(mask == 0x04) nr_[0x15] |= 0x80;
		}
	}
	static const uint8_t order[6] = {5, 2, 0, 1, 3, 4};
	for(int i = 0; i < 112; ++i) {
		const int bank = i < 6 ? order[i] : i;
		if(!bank_map[bank]) continue;
		if(!load_into(bank, 0, 0x4000)) { error = "bad_nex"; return false; }
	}

	// NextZXOS deja el color de reserva en negro al terminar de arrancar.
	nr_[0x4A] = 0;
	border_ = border & 7;
	mmu_[6] = uint8_t(entry_bank * 2);
	mmu_[7] = uint8_t(entry_bank * 2 + 1);
	remap();
	cpu_.SP = sp;
	cpu_.PC = pc;
	cpu_.IM = 1;
	cpu_.IFF1 = cpu_.IFF2 = false;
	return true;
}

}	// namespace nx
