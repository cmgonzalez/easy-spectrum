// Ratón Kempston (y, más adelante, AMX): estado compartido entre el bridge y las máquinas.
// Puertos Kempston: FBDF = X, FFDF = Y (sube hacia arriba), FADF = botones (0 = pulsado:
// bit 0 derecho, bit 1 izquierdo, bit 2 central; bits 3-7 a 1).
#pragma once
#include <stdint.h>

struct ZxMouse {
	int mode = 0;		// 0 = sin ratón, 1 = Kempston, 2 = AMX
	uint8_t x = 0, y = 0;	// contadores de 8 bits (envuelven)
	uint8_t buttons = 0;	// bit 0 izquierdo, bit 1 derecho, bit 2 central (1 = pulsado)

	// dx hacia la derecha, dy hacia abajo (convención de pantalla).
	void move(int dx, int dy) {
		x = uint8_t(x + dx);
		y = uint8_t(y - dy);
	}

	// Lectura de un puerto Kempston; false si no es de ratón (o el ratón no es Kempston).
	bool read(uint16_t port, uint8_t &value) const {
		if(mode != 1 || (port & 0xFF) != 0xDF) return false;
		switch((port >> 8) & 0x0F) {
			case 0x0B: value = x; return true;
			case 0x0F: value = y; return true;
			case 0x0A: {
				const uint8_t pressed = uint8_t(((buttons & 2) ? 1 : 0) | ((buttons & 1) ? 2 : 0) | ((buttons & 4) ? 4 : 0));
				value = uint8_t(0xF8 | (~pressed & 7));
				return true;
			}
			default: return false;
		}
	}
};

// Único para la máquina de CLK (solo hay una a la vez); la Next lleva el suyo.
inline ZxMouse g_zx_mouse;
