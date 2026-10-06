	// MARK: - Timex TC2048 / TS2068 (parche de Easy Spectrum: native/CMakeLists.txt).
	//
	// Los dos son "48K" para el resto de la máquina (base_model): sin $7FFD, sin AY de 128K,
	// RAM de 48K lineal. Diferencias:
	//	· $FF (ambos): modo de pantalla (lo dibuja Video::set_timex_mode), b6 = sin interrupción,
	//	  b7 = la MMU del TS2068 usa el EXROM (1) o el DOCK (0).
	//	· TS2068: MMU horizontal en $F4 (bit n = chunk n de 8K sale de DOCK/EXROM), AY en $F5/$F6,
	//	  joysticks por el puerto A del AY, NTSC (Video::Timing::TS2068), 3,528 MHz, $FE decodificado
	//	  completo ($F4/$F6 también tienen A0 = 0).
	// banks_ tiene 8 entradas de 8K (todos los modelos): set_memory() llena las dos de cada 16K.
	// En el código inyectado no escribir "model <op> Model::" (CMake lo cambia a base_model):
	// usar "Model::X == model".
	static constexpr bool is_timex = Model::TC2048 == model || Model::TS2068 == model;
	static constexpr Model base_model = is_timex ? Model::FortyEightK : model;

	uint8_t timex_ff_ = 0;
	uint8_t timex_f4_ = 0;
	uint8_t ts_ay_register_ = 0;
	bool timex_video_ = false;	// modo Timex activo: las escrituras en $6000-$7AFF tocan la pantalla

	static inline const std::array<uint8_t, 8192> dock_empty_ = [] {
		std::array<uint8_t, 8192> a;
		a.fill(0xff);
		return a;
	}();

	static constexpr bool ula_port(const uint16_t address) {
		if constexpr (Model::TS2068 == model) return (address & 0xff) == 0xfe;
		return !(address & 1);
	}

	uint16_t video_write_limit() const {
		return timex_video_ ? 0x3b00 : 6912;
	}

	void timex_sync_video() {
		timex_video_ = (video_.get()->timex_mode() & 7) != 0;
	}

	void timex_write_ff(const uint8_t value) {
		timex_ff_ = value;
		video_->set_timex_mode(value & 0x3f);
		timex_sync_video();
		if constexpr (Model::TS2068 == model) {
			update_memory_map();
			update_video_base();
		}
	}

	void timex_reset() {
		timex_f4_ = 0;
		ts_ay_register_ = 0;
		timex_write_ff(0);
	}

	/// TS2068: superpone el EXROM (8K, espejado) o el DOCK vacío en los chunks de $F4.
	/// Se llama al final de update_memory_map(), que antes dejó el mapa normal de 48K.
	void timex_overlay() {
		if constexpr (Model::TS2068 == model) {
			for(int c = 0; c < 8; c++) {
				if(!(timex_f4_ & (1 << c))) continue;
				auto &bank = banks_[size_t(c)];
				const uint8_t *const source = (timex_ff_ & 0x80) ? &rom_[0x4000] : dock_empty_.data();
				const auto offset = size_t(c) * 8192;
				bank.read = source - offset;
				bank.write = scratch_.data() - offset;
				bank.page = uint8_t(0x40 | c);
				bank.is_contended = false;
				bank.is_video = false;
			}
		}
	}

	/// Joysticks del TS2068 (puerto A del AY): b0 arriba, b1 abajo, b2 izquierda, b3 derecha,
	/// b7 fuego, activos a 0. A8 elige el joystick 1 y A9 el 2.
	uint8_t ts2068_joysticks(const uint16_t address) {
		const auto stick = [&](int n) -> uint8_t {
			const uint8_t k = static_cast<Joystick *>(joysticks_[size_t(n)].get())->get_kempston();
			uint8_t v = 0;
			if(k & 0x08) v |= 0x01;
			if(k & 0x04) v |= 0x02;
			if(k & 0x02) v |= 0x04;
			if(k & 0x01) v |= 0x08;
			if(k & 0x10) v |= 0x80;
			return v;
		};
		uint8_t pressed = 0;
		if(address & 0x0100) pressed |= stick(0);
		if(address & 0x0200) pressed |= stick(1);
		return uint8_t(~pressed);
	}

