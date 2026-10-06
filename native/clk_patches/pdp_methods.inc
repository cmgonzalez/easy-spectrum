public:
	// MARK: - PDP (depuración). Ver native/zx_debug.h.
	void debug_attach() {
		zxdbg::Target t;
		t.ctx = this;
		t.regs = [](void *c, zxdbg::Regs *r) { static_cast<ConcreteMachine *>(c)->debug_regs(*r); };
		t.peek = [](void *c, uint16_t a) -> uint8_t { return static_cast<ConcreteMachine *>(c)->debug_peek(a); };
		t.poke = [](void *c, uint16_t a, uint8_t v) { static_cast<ConcreteMachine *>(c)->debug_poke(a, v); };
		t.credit = [](void *c, int64_t hc) { static_cast<ConcreteMachine *>(c)->z80_.run_for(HalfCycles(hc)); };
		t.peek_bank = [](void *c, int kind, int bank, uint16_t off) -> uint8_t { return static_cast<ConcreteMachine *>(c)->debug_peek_bank(kind, bank, off); };
		t.poke_bank = [](void *c, int kind, int bank, uint16_t off, uint8_t v) { static_cast<ConcreteMachine *>(c)->debug_poke_bank(kind, bank, off, v); };
		t.paging = [](void *c, uint8_t *p7, uint8_t *p1) { auto *m = static_cast<ConcreteMachine *>(c); *p7 = m->port7ffd_; *p1 = m->port1ffd_; };
		t.machine_state = [](void *c, uint8_t *border, uint8_t ay[16], uint8_t *sel, int *hc) {
			static_cast<ConcreteMachine *>(c)->debug_machine_state(border, ay, sel, hc);
		};
		if constexpr (is_timex) {
			t.timex = [](void *c, uint8_t *ff, uint8_t *f4) { auto *m = static_cast<ConcreteMachine *>(c); *ff = m->timex_ff_; *f4 = m->timex_f4_; };
		}
		t.frame_half_cycles = (Model::TS2068 == model ? 224 * 262 : model < Model::OneTwoEightK ? 69888 : 70908) * 2;
		zxdbg::g.t = t;
		zxdbg::g.clock = zxdbg::g.last_clock = zxdbg::g.next_frame = 0;
	}

	// Borde y tiempo de vídeo por Video::State (amiga de Video); el AY por zxsnap::AyPeek
	// (clk_patches/snapshot_access.h).
	void debug_machine_state(uint8_t *border, uint8_t ay[16], uint8_t *sel, int *hc) {
		const Sinclair::ZXSpectrum::Video::State vs(*video_.get());
		*border = vs.border_colour & 7;
		*hc = vs.half_cycles_since_interrupt;
		zxsnap::AyPeek p{&ay_};
		GI::AY38910::State().apply(p);
		std::copy_n(p.regs, 16, ay);
		*sel = p.sel;
	}

	uint8_t debug_peek_bank(int kind, int bank, uint16_t off) const {
		const size_t i = size_t(bank) * 0x4000 + (off & 0x3fff);
		if(kind == 1) return i < rom_.size() ? rom_[i] : 0xff;
		return i < ram_.size() ? ram_[i] : 0xff;
	}

	void debug_poke_bank(int kind, int bank, uint16_t off, uint8_t v) {
		const size_t i = size_t(bank) * 0x4000 + (off & 0x3fff);
		if(kind == 0 && i < ram_.size()) ram_[i] = v;
	}

	void debug_regs(zxdbg::Regs &r) const {
		using R = CPU::Z80::Register;
		r.pc = z80_.value_of(R::ProgramCounter);	r.sp = z80_.value_of(R::StackPointer);
		r.af = z80_.value_of(R::AF);	r.bc = z80_.value_of(R::BC);
		r.de = z80_.value_of(R::DE);	r.hl = z80_.value_of(R::HL);
		r.af2 = z80_.value_of(R::AFDash);	r.bc2 = z80_.value_of(R::BCDash);
		r.de2 = z80_.value_of(R::DEDash);	r.hl2 = z80_.value_of(R::HLDash);
		r.ix = z80_.value_of(R::IX);	r.iy = z80_.value_of(R::IY);
		r.memptr = z80_.value_of(R::MemPtr);
		r.i = uint8_t(z80_.value_of(R::I));	r.r = uint8_t(z80_.value_of(R::R));
		r.iff1 = uint8_t(z80_.value_of(R::IFF1));	r.iff2 = uint8_t(z80_.value_of(R::IFF2));
		r.im = uint8_t(z80_.value_of(R::IM));
	}

	uint8_t debug_peek(uint16_t address) const {
		return banks_[address >> 14].read[address];
	}

	void debug_poke(uint16_t address, uint8_t value) {
		if(banks_[address >> 14].is_video && (address & 0x3fff) < 6912) video_.flush();
		banks_[address >> 14].write[address] = value;
	}

