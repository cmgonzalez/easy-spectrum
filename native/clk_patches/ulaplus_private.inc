	// MARK: - ULAplus y paleta (salida Red8Green8Blue8: bytes R, G, B, 0).
	uint8_t ulaplus_register_ = 0;
	uint8_t ulaplus_mode_ = 0;
	uint8_t flash_enable_ = 1;	// 0 con la paleta ULAplus activa: FLASH elige CLUT, no parpadea
	uint8_t ulaplus_palette_[64]{};
	uint32_t ulaplus_rgb_[64]{};

	static constexpr uint32_t level3(const uint32_t c) {
		return (c << 5) | (c << 2) | (c >> 1);
	}

	/// Entrada ULAplus GRB 3-3-2 → RGB de 8 bits. El azul tiene 2 bits: el tercero (el bajo)
	/// es el OR de los dos, como indica la especificación.
	static constexpr uint32_t ulaplus_colour(const uint8_t v) {
		const uint32_t b = v & 3;
		return level3((v >> 2) & 7) | (level3(v >> 5) << 8) | (level3((b << 1) | (b ? 1 : 0)) << 16);
	}

	uint32_t ink_colour(const uint8_t attribute) const {
		if(ulaplus_mode_ & 1) return ulaplus_rgb_[((attribute & 0xc0) >> 2) | (attribute & 0x07)];
		return palette[((attribute & 0x40) >> 3) | (attribute & 0x07)];
	}

	uint32_t paper_colour(const uint8_t attribute) const {
		if(ulaplus_mode_ & 1) return ulaplus_rgb_[((attribute & 0xc0) >> 2) | 8 | ((attribute >> 3) & 0x07)];
		return palette[(attribute & 0x78) >> 3];
	}

	uint32_t border_rgb(const uint8_t colour) const {
		return (ulaplus_mode_ & 1) ? ulaplus_rgb_[8 | colour] : palette[colour];
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
