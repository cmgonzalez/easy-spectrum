	// MARK: - ULAplus (parche de Easy Spectrum: native/clk_patches, native/CMakeLists.txt).
	//
	// Puerto 0xBF3B (registro): b7-6 = grupo (00 paleta, 01 modo), b5-0 = entrada de paleta.
	// Puerto 0xFF3B (dato, lectura y escritura): la entrada elegida (GRB 3-3-2) o el modo
	// (b0 = paleta activa). Con la paleta activa, FLASH y BRIGHT eligen una de 4 CLUT de 16
	// colores (tintas 0-7, papeles 8-15), FLASH deja de parpadear y el borde usa los papeles
	// de la CLUT 0.
	void ulaplus_write_register(const uint8_t value) {
		ulaplus_register_ = value;
	}

	void ulaplus_write_data(const uint8_t value) {
		switch(ulaplus_register_ & 0xc0) {
			case 0x00:
				ulaplus_palette_[ulaplus_register_ & 0x3f] = value;
				ulaplus_rgb_[ulaplus_register_ & 0x3f] = ulaplus_colour(value);
			break;
			case 0x40:
				ulaplus_mode_ = value;
				flash_enable_ = (value & 1) ? 0 : 1;
			break;
			default: return;
		}
		set_border_colour(border_byte_);
	}

	uint8_t ulaplus_read_data() const {
		switch(ulaplus_register_ & 0xc0) {
			case 0x00:	return ulaplus_palette_[ulaplus_register_ & 0x3f];
			case 0x40:	return ulaplus_mode_;
			default:	return 0xff;
		}
	}

	/// Reset de la máquina: la paleta se conserva, el modo ULAplus se apaga.
	void ulaplus_reset() {
		ulaplus_register_ = 0;
		ulaplus_mode_ = 0;
		flash_enable_ = 1;
		set_border_colour(border_byte_);
	}

