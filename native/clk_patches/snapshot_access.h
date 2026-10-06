// Lectura de los registros del AY de CLK para guardar snapshots (zx_save_snapshot).
//
// CLK no expone registers_ / selected_register_ del AY, pero declara amiga a
// GI::AY38910::State: una especialización de su plantilla apply<> con un tipo propio
// es miembro de State y puede leerlos sin tocar el submódulo.
#pragma once
#include "Components/AY38910/AY38910.hpp"
#include <cstdint>

namespace zxsnap {
struct AyPeek {
	const GI::AY38910::AY38910SampleSource<false> *ay;
	uint8_t regs[16]{};
	uint8_t sel = 0;
};
}

template <> inline void GI::AY38910::State::apply<zxsnap::AyPeek>(zxsnap::AyPeek &p) {
	for(int c = 0; c < 16; c++) p.regs[c] = p.ay->registers_[c];
	p.sel = uint8_t(p.ay->selected_register_ & 0x0f);
}
