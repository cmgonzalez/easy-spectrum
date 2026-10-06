	// MARK: - ULAplus y paleta (salida Red8Green8Blue8: bytes R, G, B, 0).
	uint8_t ulaplus_register_ = 0;
	uint8_t ulaplus_mode_ = 0;
	uint8_t flash_enable_ = 1;	// 0 con la paleta ULAplus activa: FLASH elige CLUT, no parpadea
	uint8_t ulaplus_palette_[64]{};
	uint32_t ulaplus_rgb_[64]{};
	uint8_t timex_mode_ = 0;	// modo de vídeo Timex (b0-5 del puerto $FF), ver set_timex_mode

	static constexpr uint32_t level3(const uint32_t c) {
		return (c << 5) | (c << 2) | (c >> 1);
	}

	/// Entrada ULAplus GRB 3-3-2 → RGB de 8 bits. El azul tiene 2 bits: el tercero (el bajo)
	/// es el OR de los dos, como indica la especificación.
	static constexpr uint32_t ulaplus_colour(const uint8_t v) {
		const uint32_t b = v & 3;
		return level3((v >> 2) & 7) | (level3(v >> 5) << 8) | (level3((b << 1) | (b ? 1 : 0)) << 16);
	}

	/// Paleta ULAplus en uso (el ajuste zx_ulaplus_mode = 0 la apaga aunque el programa la active).
	bool ulaplus_on() const {
		return (ulaplus_mode_ & 1) && ::zx_ulaplus_mode;
	}

	/// Escala de grises de ULAplus (bit 1 del modo): "como quitar el color en el televisor".
	bool ulaplus_grey() const {
		return (ulaplus_mode_ & 2) && ::zx_ulaplus_mode;
	}

	static constexpr uint32_t grey(const uint32_t c) {
		const uint32_t y = ((c & 0xff) * 77 + ((c >> 8) & 0xff) * 150 + ((c >> 16) & 0xff) * 29) >> 8;
		return y | (y << 8) | (y << 16);
	}

	uint32_t ink_colour(const uint8_t attribute) const {
		if(ulaplus_on()) return ulaplus_rgb_[((attribute & 0xc0) >> 2) | (attribute & 0x07)];
		return palette[((attribute & 0x40) >> 3) | (attribute & 0x07)];
	}

	uint32_t paper_colour(const uint8_t attribute) const {
		if(ulaplus_on()) return ulaplus_rgb_[((attribute & 0xc0) >> 2) | 8 | ((attribute >> 3) & 0x07)];
		return palette[(attribute & 0x78) >> 3];
	}

	/// Colores del hi-res Timex: tinta = b3-5 del modo, papel = su complemento, con BRIGHT. Con
	/// ULAplus: tinta 24 + b3-5 y papel 31 - b3-5 (CLUT 3, tabla de la especificación).
	uint32_t hires_ink() const {
		const int c = (timex_mode_ >> 3) & 7;
		const uint32_t rgb = ulaplus_on() ? ulaplus_rgb_[24 + c] : palette[8 + c];
		return ulaplus_grey() ? grey(rgb) : rgb;
	}

	uint32_t hires_paper() const {
		const int c = (timex_mode_ >> 3) & 7;
		const uint32_t rgb = ulaplus_on() ? ulaplus_rgb_[31 - c] : palette[15 - c];
		return ulaplus_grey() ? grey(rgb) : rgb;
	}

	uint32_t border_rgb(const uint8_t colour) const {
		if(timex_mode_ & 4) return hires_paper();
		const uint32_t rgb = ulaplus_on() ? ulaplus_rgb_[8 | colour] : palette[colour];
		return ulaplus_grey() ? grey(rgb) : rgb;
	}

	/// 8 píxeles normales (o hi-color) con su atributo.
	void output_byte(uint8_t pixels, const uint8_t attribute) {
		const bool ulaplus = ulaplus_on();
		if(!ulaplus && flash_mask_ && (attribute & 0x80)) pixels ^= 0xff;
		uint32_t colours[2] = {paper_colour(attribute), ink_colour(attribute)};
		if(ulaplus_grey()) {
			colours[0] = grey(colours[0]);
			colours[1] = grey(colours[1]);
		}
		pixel_target_[0] = colours[(pixels >> 7) & 1];
		pixel_target_[1] = colours[(pixels >> 6) & 1];
		pixel_target_[2] = colours[(pixels >> 5) & 1];
		pixel_target_[3] = colours[(pixels >> 4) & 1];
		pixel_target_[4] = colours[(pixels >> 3) & 1];
		pixel_target_[5] = colours[(pixels >> 2) & 1];
		pixel_target_[6] = colours[(pixels >> 1) & 1];
		pixel_target_[7] = colours[(pixels >> 0) & 1];
		pixel_target_ += 8;
	}

	/// Hi-res: 8 píxeles de 512 en 4 muestras (cada una, la media de un par). La salida es de
	/// 256 muestras por línea como el resto; el detalle de 512 se pierde (fase 1).
	void output_hires_byte(const uint8_t pixels, const uint32_t ink, const uint32_t paper) {
		const uint32_t mid = (((ink & 0xfefefe) >> 1) + ((paper & 0xfefefe) >> 1));
		for(int n = 0; n < 4; n++) {
			switch((pixels >> (6 - 2 * n)) & 3) {
				case 0: pixel_target_[n] = paper;	break;
				case 3: pixel_target_[n] = ink;		break;
				default: pixel_target_[n] = mid;	break;
			}
		}
		pixel_target_ += 4;
	}

	/// Una columna de 16 píxeles (2 bytes de pantalla) según el modo Timex.
	void output_column() {
		const int mode = timex_mode_ & 7;
		if(mode & 4) {
			last_fetches_[0] = memory_[pixel_address_];
			last_fetches_[1] = memory_[pixel_address_ + 0x2000];
			last_fetches_[2] = memory_[pixel_address_ + 1];
			last_fetches_[3] = memory_[pixel_address_ + 0x2001];
			const uint32_t ink = hires_ink(), paper = hires_paper();
			for(int n = 0; n < 4; n++) output_hires_byte(last_fetches_[n], ink, paper);
		} else {
			const int pixels = (mode == 1) ? pixel_address_ + 0x2000 : pixel_address_;
			const int attributes =
				(mode & 2) ? pixel_address_ + 0x2000 :
				(mode & 1) ? attribute_address_ + 0x2000 : attribute_address_;
			last_fetches_[0] = memory_[pixels];
			last_fetches_[1] = memory_[attributes];
			last_fetches_[2] = memory_[pixels + 1];
			last_fetches_[3] = memory_[attributes + 1];
			output_byte(last_fetches_[0], last_fetches_[1]);
			output_byte(last_fetches_[2], last_fetches_[3]);
		}
		set_last_contended_area_access(last_fetches_[3]);
		pixel_address_ += 2;
		attribute_address_ += 2;
	}

	// Los 16 colores normales (0xD7 sin BRIGHT, 0xFF con BRIGHT): los mismos niveles que antes.
#define RGB(r, g, b)	(uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16))
	static constexpr uint32_t palette[] = {
		RGB(0, 0, 0),		RGB(0, 0, 0xd7),	RGB(0xd7, 0, 0),	RGB(0xd7, 0, 0xd7),
		RGB(0, 0xd7, 0),	RGB(0, 0xd7, 0xd7),	RGB(0xd7, 0xd7, 0),	RGB(0xd7, 0xd7, 0xd7),
		RGB(0, 0, 0),		RGB(0, 0, 0xff),	RGB(0xff, 0, 0),	RGB(0xff, 0, 0xff),
		RGB(0, 0xff, 0),	RGB(0, 0xff, 0xff),	RGB(0xff, 0xff, 0),	RGB(0xff, 0xff, 0xff),
	};
#undef RGB
