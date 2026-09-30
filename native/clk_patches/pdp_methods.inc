public:
	// MARK: - PDP (depuración). Ver native/zx_debug.h.
	void debug_attach() {
		zxdbg::Target t;
		t.ctx = this;
		t.regs = [](void *c, zxdbg::Regs *r) { static_cast<ConcreteMachine *>(c)->debug_regs(*r); };
		t.peek = [](void *c, uint16_t a) -> uint8_t { return static_cast<ConcreteMachine *>(c)->debug_peek(a); };
		t.poke = [](void *c, uint16_t a, uint8_t v) { static_cast<ConcreteMachine *>(c)->debug_poke(a, v); };
		t.credit = [](void *c, int64_t hc) { static_cast<ConcreteMachine *>(c)->z80_.run_for(HalfCycles(hc)); };
		zxdbg::g.t = t;
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

