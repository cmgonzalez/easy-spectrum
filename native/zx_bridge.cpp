/*
 * zx_bridge.cpp — wrapper C sobre Clock Signal (CLK, Thomas Harte, MIT) para dart:ffi.
 *
 * CLK entrega el vídeo como "scans" de un CRT simulado (Outputs::Display::ScanTarget),
 * pensado para un backend OpenGL. Aquí se implementa un ScanTarget por software que
 * rasteriza esos scans a un framebuffer RGBA fijo de 320×256 (pantalla + borde).
 *
 * Calibración: la posición horizontal se obtiene de los scans de papel (256 muestras),
 * la vertical contando fin-de-retrazo horizontal desde el último retrazo vertical.
 */

#include "zx_bridge.h"
#include "next/next_machine.h"
#include "zx_mouse.h"
#include "zx_debug.h"
#include "zx_pdp.h"
#include "zx_tape.h"

#include "Machines/Sinclair/ZXSpectrum/ZXSpectrum.hpp"
#include "Machines/Sinclair/Keyboard/Keyboard.hpp"
#include "Analyser/Static/ZXSpectrum/Target.hpp"
#include "Machines/MachineTypes.hpp"
#include "Machines/Utility/ROMCatalogue.hpp"
#include "Outputs/ScanTarget.hpp"
#include "Outputs/Speaker/Speaker.hpp"

#include "Storage/Tape/Formats/ZXSpectrumTAP.hpp"
#include "Storage/Tape/Formats/TZX.hpp"
#include "Storage/Tape/Formats/CSW.hpp"
#include "Storage/Disk/DiskImage/DiskImage.hpp"
#include "Storage/Disk/DiskImage/Formats/CPCDSK.hpp"
#include "Storage/State/Z80.hpp"
#include "Storage/State/SNA.hpp"
#include "Storage/State/SZX.hpp"
#include "Machines/Sinclair/ZXSpectrum/State.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "zx_bridge", __VA_ARGS__)
#else
#define LOGI(...) do {} while(0)
#endif

namespace {

constexpr int FbW = ZX_FB_WIDTH;
constexpr int FbH = ZX_FB_HEIGHT;
constexpr int BorderX = (FbW - 256) / 2;
constexpr int BorderY = (FbH - 192) / 2;

std::string g_last_error;

// Niveles de 2 bits del ULA → 8 bits (0 = apagado, 2 = normal, 3 = brillo).
constexpr uint8_t Level2[4] = {0x00, 0x60, 0xD7, 0xFF};

// ---------------------------------------------------------------------------
// ScanTarget por software
// ---------------------------------------------------------------------------
class SoftScanTarget: public Outputs::Display::ScanTarget {
public:
	SoftScanTarget() {
		work_.fill(0xff000000u);
		front_.fill(0xff000000u);
	}

	void set_modals(Modals modals) override {
		modals_ = modals;
	}

	void set_delegate(Delegate &delegate) override {
		Delegate::Preferences prefs;
		prefs.force_horizontal_scans = true;
		delegate.set(prefs);
	}

	Scan *begin_scan() override { return &scan_; }

	uint8_t *begin_data(size_t required_length, size_t required_alignment) override {
		if(required_length + required_alignment > data_.size()) return nullptr;
		data_length_ = required_length;
		auto base = reinterpret_cast<uintptr_t>(data_.data());
		base = (base + required_alignment - 1) / required_alignment * required_alignment;
		data_ptr_ = reinterpret_cast<uint8_t *>(base);
		return data_ptr_;
	}

	/// Sin dibujar (turbo de carga): se siguen contando líneas y retrazos para no perder
	/// la posición vertical, pero no se rasteriza ni se publica nada.
	void set_drawing(bool drawing) {
		drawing_ = drawing;
		if(!drawing) frame_clean_ = false;
	}

	/// Gigascreen: cada frame publicado es la mezcla del actual con el anterior (los
	/// programas alternan dos pantallas a 50 Hz y el ojo ve el promedio). Se mezcla en luz
	/// lineal, como el parpadeo real: negro + blanco = gris claro, no gris medio.
	void set_gigascreen(bool enabled) {
		gigascreen_ = enabled;
		prev_valid_ = false;
		if(enabled && !gamma_ready_) {
			for(int i = 0; i < 256; i++) {
				to_linear_[i] = uint16_t(std::lround(std::pow(i / 255.0, 2.2) * 4095.0));
			}
			for(int i = 0; i < 4096; i++) {
				to_srgb_[i] = uint8_t(std::lround(std::pow(i / 4095.0, 1 / 2.2) * 255.0));
			}
			gamma_ready_ = true;
		}
	}

	void end_scan() override {
		if(!drawing_ || !data_ptr_ || !data_length_) return;
		const auto &p0 = scan_.end_points[0];
		const auto &p1 = scan_.end_points[1];
		const int off0 = p0.data_offset, off1 = p1.data_offset;
		const float x0 = p0.x, x1 = p1.x;
		if(x1 <= x0) return;

		// Calibración horizontal con cualquier tramo largo de datos (papel).
		if(off1 - off0 >= 64) {
			const float upp = (x1 - x0) / float(off1 - off0);
			const float left = x0 - float(off0) * upp;
			if(!h_calibrated_) {
				units_per_pixel_ = upp;
				paper_left_ = left;
				h_calibrated_ = true;
			}
			if(line_ < frame_min_data_line_) frame_min_data_line_ = line_;
		}
		if(!h_calibrated_ || !v_calibrated_) return;

		const int row = line_ - paper_top_line_ + BorderY;
		if(row < 0 || row >= FbH) return;

		const float fc0 = (x0 - paper_left_) / units_per_pixel_ + BorderX;
		const float fc1 = (x1 - paper_left_) / units_per_pixel_ + BorderX;
		int c0 = int(fc0 + 0.5f), c1 = int(fc1 + 0.5f);
		const int span = std::max(c1 - c0, 1);
		const int first = std::max(c0, 0), last = std::min(c1, FbW);
		if(first >= last) return;

		uint32_t *const dst = &work_[size_t(row) * FbW];
		const int n = int(data_length_);
		const int doff = off1 - off0;
		for(int c = first; c < last; ++c) {
			int idx = off0 + ((c - c0) * doff + doff / 2) / span;
			if(idx >= n) idx = n - 1;
			if(idx < 0) idx = 0;
			dst[c] = colour(idx);
		}
	}

	void announce(Event event, bool, const Scan::EndPoint &, uint8_t) override {
		switch(event) {
			case Event::EndHorizontalRetrace:
				++line_;
			break;
			case Event::BeginVerticalRetrace: {
				// Solo frames dibujados de principio a fin: uno parcial (tras salir del
				// turbo) saldría mezclado y recalibraría mal la línea superior del papel.
				if(!frame_clean_) break;
				{
					std::lock_guard lock(fb_mutex_);
					if(gigascreen_ && prev_valid_) {
						blend_into_front();
					} else {
						front_ = work_;
					}
				}
				if(gigascreen_) {
					prev_ = work_;
					prev_valid_ = true;
				}
				++frames_;
				// Ajustar la línea superior del papel (estable tras el primer frame).
				if(frame_min_data_line_ != INT32_MAX) {
					if(!v_calibrated_ || frame_min_data_line_ != paper_top_line_) {
						paper_top_line_ = frame_min_data_line_;
						v_calibrated_ = true;
					}
				}
			} break;
			case Event::EndVerticalRetrace:
				line_ = 0;
				frame_min_data_line_ = INT32_MAX;
				frame_clean_ = drawing_;
			break;
			default: break;
		}
	}

	int take_frames() {
		const int f = frames_;
		frames_ = 0;
		return f;
	}

	const uint8_t *front() {
		std::lock_guard lock(fb_mutex_);
		std::memcpy(snapshot_.data(), front_.data(), front_.size() * 4);
		return reinterpret_cast<const uint8_t *>(snapshot_.data());
	}

private:
	void blend_into_front() {
		for(size_t i = 0; i < work_.size(); i++) {
			const uint32_t a = work_[i], b = prev_[i];
			if(a == b) {
				front_[i] = a;
				continue;
			}
			uint32_t out = 0xff000000u;
			for(int shift = 0; shift < 24; shift += 8) {
				const int la = to_linear_[(a >> shift) & 0xff], lb = to_linear_[(b >> shift) & 0xff];
				out |= uint32_t(to_srgb_[(la + lb) >> 1]) << shift;
			}
			front_[i] = out;
		}
	}

	uint32_t colour(int idx) const {
		using T = Outputs::Display::InputDataType;
		uint8_t r = 0, g = 0, b = 0;
		switch(modals_.input_data_type) {
			case T::Red2Green2Blue2: {
				const uint8_t v = data_ptr_[idx];
				r = Level2[(v >> 4) & 3]; g = Level2[(v >> 2) & 3]; b = Level2[v & 3];
			} break;
			case T::Red1Green1Blue1: {
				const uint8_t v = data_ptr_[idx];
				r = (v & 4) ? 0xff : 0; g = (v & 2) ? 0xff : 0; b = (v & 1) ? 0xff : 0;
			} break;
			case T::Red8Green8Blue8: {
				const uint8_t *v = &data_ptr_[idx * 4];
				r = v[0]; g = v[1]; b = v[2];
			} break;
			case T::Luminance8: r = g = b = data_ptr_[idx]; break;
			case T::Luminance1: r = g = b = data_ptr_[idx] ? 0xff : 0; break;
			default: break;
		}
		// RGBA8888 en memoria little-endian → 0xAABBGGRR.
		return 0xff000000u | (uint32_t(b) << 16) | (uint32_t(g) << 8) | r;
	}

	Modals modals_{};
	Scan scan_{};
	alignas(16) std::array<uint8_t, 8192> data_{};
	uint8_t *data_ptr_ = nullptr;
	size_t data_length_ = 0;

	int line_ = 0;
	bool h_calibrated_ = false, v_calibrated_ = false;
	float units_per_pixel_ = 1.0f, paper_left_ = 0.0f;
	int paper_top_line_ = 0;
	int frame_min_data_line_ = INT32_MAX;
	int frames_ = 0;
	bool drawing_ = true;
	bool frame_clean_ = false;	// se dibujó desde el último EndVerticalRetrace

	std::array<uint32_t, FbW * FbH> work_{}, front_{}, snapshot_{}, prev_{};
	std::mutex fb_mutex_;

	bool gigascreen_ = false, prev_valid_ = false, gamma_ready_ = false;
	std::array<uint16_t, 256> to_linear_{};
	std::array<uint8_t, 4096> to_srgb_{};
};

// ---------------------------------------------------------------------------
// Audio: ring buffer int16 alimentado por el delegate del Speaker (otro hilo).
// ---------------------------------------------------------------------------
class AudioRing: public Outputs::Speaker::Speaker::Delegate {
public:
	explicit AudioRing(size_t capacity) : buf_(capacity) {}

	void speaker_did_complete_samples(Outputs::Speaker::Speaker &, const std::vector<int16_t> &buffer) override {
		if(muted_.load(std::memory_order_relaxed)) return;
		std::lock_guard lock(mutex_);
		for(const int16_t s : buffer) {
			if(count_ == buf_.size()) {	// lleno: descartar lo más viejo
				read_ = (read_ + 1) % buf_.size();
				--count_;
			}
			buf_[write_] = s;
			write_ = (write_ + 1) % buf_.size();
			++count_;
		}
	}

	/// Silencio durante el turbo de carga: el audio acelerado no sirve y desbordaría el buffer.
	void set_muted(bool muted) {
		muted_.store(muted, std::memory_order_relaxed);
		if(muted) {
			std::lock_guard lock(mutex_);
			read_ = write_ = count_ = 0;
		}
	}

	int drain(int16_t *out, int max) {
		std::lock_guard lock(mutex_);
		// Mantener pares L/R alineados.
		int n = int(std::min<size_t>(count_, size_t(max))) & ~1;
		for(int i = 0; i < n; ++i) {
			out[i] = buf_[read_];
			read_ = (read_ + 1) % buf_.size();
		}
		count_ -= size_t(n);
		return n;
	}

private:
	std::vector<int16_t> buf_;
	size_t read_ = 0, write_ = 0, count_ = 0;
	std::mutex mutex_;
	std::atomic<bool> muted_{false};
};

bool read_file(const std::string &path, std::vector<uint8_t> &out) {
	std::ifstream f(path, std::ios::binary);
	if(!f) return false;
	out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
	return !out.empty();
}

std::string lower_ext(const std::string &path) {
	const auto dot = path.find_last_of('.');
	if(dot == std::string::npos) return "";
	std::string ext = path.substr(dot + 1);
	std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return char(std::tolower(c)); });
	return ext;
}

/*
 * SNA de 128K. Storage::State::SNA de CLK solo acepta el de 48K (49179 bytes).
 * Formato: cabecera de 27 bytes (igual que 48K) + 48K de RAM (bancos 5, 2 y el
 * paginado en 0xC000) + PC (2) + puerto 7FFD (1) + TR-DOS (1) + resto de bancos
 * en orden ascendente, omitiendo 5, 2 y el paginado (5 bancos; 6 si el paginado
 * es el 2 o el 5, que entonces ya vino repetido dentro de los primeros 48K).
 */
// CLK interpreta el campo de hardware de los .z80 v3 (cabecera de 54/55 bytes) con la tabla de
// la v2: en la v3 el 128K es 4 (5/6 con IF1/MGT) y el 3 es "48K + MGT". Se corrige una copia
// temporal junto al archivo y se vuelve a cargar.
std::unique_ptr<Analyser::Static::Target> load_z80(const std::string &path) {
	auto t = Storage::State::Z80::load(path);
	if(t) return t;
	std::vector<uint8_t> d;
	if(!read_file(path, d) || d.size() < 35) return nullptr;
	const unsigned bonus = d[30] | (d[31] << 8);
	if(d[6] || d[7] || (bonus != 54 && bonus != 55)) return nullptr;
	const uint8_t m = d[34];
	if(m >= 4 && m <= 6) d[34] = 3;
	else if(m == 3) d[34] = 0;
	else if(m == 9) d[34] = 3;	// Pentagon 128
	else return nullptr;
	const std::string tmp = path + ".fix";
	{
		std::ofstream f(tmp, std::ios::binary);
		f.write(reinterpret_cast<const char *>(d.data()), std::streamsize(d.size()));
		if(!f) return nullptr;
	}
	t = Storage::State::Z80::load(tmp);
	std::remove(tmp.c_str());
	return t;
}

std::unique_ptr<Analyser::Static::Target> load_sna128(const std::string &path) {
	using Target = Analyser::Static::ZXSpectrum::Target;
	constexpr size_t Bank = 16 * 1024;
	constexpr size_t Header = 27;
	constexpr size_t Tail = Header + 3 * Bank + 4;

	std::vector<uint8_t> f;
	if(!read_file(path, f)) return nullptr;
	if(f.size() != Tail + 5 * Bank && f.size() != Tail + 6 * Bank) return nullptr;

	const auto le16 = [&](size_t o) { return uint16_t(f[o] | (f[o + 1] << 8)); };
	const uint8_t port7ffd = f[Header + 3 * Bank + 2];
	const int paged = port7ffd & 7;
	// Con el banco paginado igual a 2 o 5 el archivo trae 6 bancos más; si no, 5.
	if((paged == 2 || paged == 5) != (f.size() == Tail + 6 * Bank)) return nullptr;

	auto result = std::make_unique<Target>();
	result->model = Target::Model::OneTwoEightK;
	auto *const state = new Sinclair::ZXSpectrum::State();
	result->state = std::unique_ptr<Reflection::Struct>(state);

	auto &r = state->z80.registers;
	r.ir = uint16_t((f[0x00] << 8) | f[0x14]);
	r.hl_dash = le16(0x01); r.de_dash = le16(0x03); r.bc_dash = le16(0x05); r.af_dash = le16(0x07);
	r.hl = le16(0x09); r.de = le16(0x0b); r.bc = le16(0x0d); r.iy = le16(0x0f); r.ix = le16(0x11);
	r.iff1 = r.iff2 = (f[0x13] & 4) != 0;
	r.flags = f[0x15]; r.a = f[0x16];
	r.stack_pointer = le16(0x17);
	r.interrupt_mode = f[0x19] & 3;
	r.program_counter = le16(Header + 3 * Bank);
	r.memptr = r.program_counter;
	state->video.border_colour = f[0x1a] & 7;
	state->last_7ffd = port7ffd;

	// RAM de 128K en orden de banco 0..7.
	state->ram.assign(8 * Bank, 0);
	const auto put = [&](int bank, size_t offset) {
		std::copy_n(&f[offset], Bank, &state->ram[size_t(bank) * Bank]);
	};
	put(5, Header);
	put(2, Header + Bank);
	put(paged, Header + 2 * Bank);
	size_t offset = Tail;
	for(int bank = 0; bank < 8; ++bank) {
		if(bank == 5 || bank == 2 || bank == paged) continue;
		put(bank, offset);
		offset += Bank;
	}
	return result;
}

// ---------------------------------------------------------------------------
// Gestor de cintas (zx_tape.h, doc/TAPE_MANAGER.md)
// ---------------------------------------------------------------------------

/// Offsets de los bloques de un .tap (cada uno: longitud de 2 bytes + bloque).
std::vector<long> scan_tap(const std::vector<uint8_t> &d) {
	std::vector<long> out;
	size_t p = 0;
	while(p + 2 <= d.size()) {
		const size_t len = size_t(d[p] | (d[p + 1] << 8));
		if(p + 2 + len > d.size()) break;
		out.push_back(long(p));
		p += 2 + len;
	}
	return out;
}

/// Offsets de los bloques de un .tzx (después de la cabecera de 10 bytes). Se detiene en un
/// ID desconocido, igual que CLK (en TZX cada bloque declara su longitud a su manera).
std::vector<long> scan_tzx(const std::vector<uint8_t> &d) {
	std::vector<long> out;
	if(d.size() < 10 || std::memcmp(d.data(), "ZXTape!\x1a", 8) != 0) return out;
	const auto le = [&d](size_t at, int n) -> size_t {
		size_t v = 0;
		for(int i = 0; i < n; i++) v |= at + i < d.size() ? size_t(d[at + i]) << (8 * i) : 0;
		return v;
	};
	size_t p = 10;
	while(p < d.size()) {
		const uint8_t id = d[p];
		const size_t b = p + 1;	// cuerpo del bloque
		size_t len;
		switch(id) {
			case 0x10: len = 4 + le(b + 2, 2); break;
			case 0x11: len = 18 + le(b + 15, 3); break;
			case 0x12: len = 4; break;
			case 0x13: len = 1 + le(b, 1) * 2; break;
			case 0x14: len = 10 + le(b + 7, 3); break;
			case 0x15: len = 8 + le(b + 5, 3); break;
			case 0x18: case 0x19: case 0x2b: case 0x4b: len = 4 + le(b, 4); break;
			case 0x20: case 0x23: case 0x24: len = 2; break;
			case 0x21: case 0x30: len = 1 + le(b, 1); break;
			case 0x22: case 0x25: case 0x27: len = 0; break;
			case 0x26: len = 2 + le(b, 2) * 2; break;
			case 0x28: case 0x32: len = 2 + le(b, 2); break;
			case 0x2a: len = 4; break;
			case 0x31: len = 2 + le(b + 1, 1); break;
			case 0x33: len = 1 + le(b, 1) * 3; break;
			case 0x35: len = 20 + le(b + 16, 4); break;
			case 0x5a: len = 9; break;
			default: return out;
		}
		if(b + len > d.size()) break;
		out.push_back(long(p));
		p = b + len;
	}
	return out;
}

/// Cinta insertada. La máquina es única, así que el estado es global (lo actualizan los
/// ganchos de las copias parcheadas de CLK).
struct TapeState {
	bool loaded = false;	// hay cinta con lista de bloques (.tap/.tzx)
	bool any = false;	// hay cinta (incluye .csw, sin lista)
	bool tzx = false;
	std::vector<uint8_t> data;	// contenido del archivo insertado
	std::vector<long> offsets;	// offset de cada bloque en `data`
	// Archivo que suena: el original o un recorte desde el bloque `base` (seek).
	int base = 0;
	long header = 0;	// bytes de cabecera del recorte (10 en .tzx, 0 en .tap y en el original)
	long base_offset = 0;	// offset en `data` del primer bloque del recorte
	long last = -1;	// último offset avisado por CLK (en el archivo que suena); -1 = aún nada
	bool recording = false;
	std::vector<uint8_t> rec;	// bloques grabados, en formato .tap (longitud + bloque)

	void clear_media() {
		loaded = any = tzx = false;
		data.clear();
		offsets.clear();
		base = 0;
		header = base_offset = 0;
		last = -1;
	}

	/// Índice del bloque que suena (offsets.size() = fin de cinta).
	int current() const {
		if(!loaded || offsets.empty()) return 0;
		if(last < 0) return base;
		const long o = last - header + base_offset;
		if(o >= long(data.size())) return int(offsets.size());
		const auto it = std::upper_bound(offsets.begin(), offsets.end(), o);
		return it == offsets.begin() ? 0 : int(it - offsets.begin()) - 1;
	}
} g_tape;

}	// namespace

namespace zxtape {
void note_block(long offset) { g_tape.last = offset; }
bool recording() { return g_tape.recording; }
void record_block(const uint8_t *data, size_t length) {
	if(length > 0xffff) return;
	g_tape.rec.push_back(uint8_t(length & 0xff));
	g_tape.rec.push_back(uint8_t(length >> 8));
	g_tape.rec.insert(g_tape.rec.end(), data, data + length);
}
}	// namespace zxtape

// ---------------------------------------------------------------------------

/* Estado de ULAplus: lo escribe el parche de Video.hpp (native/clk_patches). */
volatile int zx_ulaplus_active = 0;

struct ZxHandle {
	int model = ZX_MODEL_48K;	// modelo real (ver zx_get_model)
	// ZX Spectrum Next (solo .nex): máquina propia; si está, `machine` queda vacío.
	std::unique_ptr<nx::NextMachine> next;
	std::vector<uint8_t> next_file;	// copia del .nex para reiniciar
	std::unique_ptr<Sinclair::ZXSpectrum::Machine> machine;
	MachineTypes::TimedMachine *timed = nullptr;
	MachineTypes::KeyboardMachine *keyboard = nullptr;
	MachineTypes::JoystickMachine *joysticks = nullptr;
	MachineTypes::SoftResettable *resettable = nullptr;
	Configurable::Device *configurable = nullptr;
	MachineTypes::ScanProducer *scan_producer = nullptr;
	Outputs::Speaker::Speaker *speaker = nullptr;

	SoftScanTarget scan_target;
	AudioRing audio{48000 * 2};	// ~0.5 s estéreo a 48 kHz
	int joy_mask = 0;
	bool turbo_load = true;	// acelerar mientras gira la cinta (ver zx_run)
	bool in_turbo = false;
	// Una pulsación del usuario durante el turbo lo suspende hasta que el motor se
	// detenga (menús de juegos multicarga que leen el teclado con la cinta a medias).
	bool turbo_suppressed = false;
	double emulated = 0.0;	// segundos emulados desde zx_create
	bool pdp = false;	// este handle es el dueno del servidor de depuracion (PDP)
	std::string rom_dir;	// carpeta de las ROMs (con permiso de escritura: recortes de cinta)
	// Cinta en pausa (gestor de cintas): sin motor automático, para que el cargador que
	// sigue leyendo el puerto FE no la vuelva a arrancar.
	bool tape_paused = false;
	bool tape_seek_flip = false;

	// Secuencia de teclas con tiempos propios (el Typer de CLK va demasiado rápido
	// para el debounce del ROM 48K: dos comillas seguidas se leen como una).
	struct KeyStep { double at; uint16_t key; bool press; };
	std::vector<KeyStep> script;
	size_t script_pos = 0;
	double clock = 0.0;

	void add_press(double &t, std::initializer_list<uint16_t> keys) {
		for(const auto k : keys) script.push_back({t, k, true});
		t += 0.12;
		for(const auto k : keys) script.push_back({t, k, false});
		t += 0.20;
	}
};

/// Lee la cinta para el gestor (lista de bloques). Se llama antes de que CLK la abra.
static void tape_load_state(const std::string &path) {
	g_tape.clear_media();
	g_tape.any = true;
	const std::string ext = lower_ext(path);
	if(ext != "tap" && ext != "tzx") return;
	if(!read_file(path, g_tape.data)) return;
	g_tape.tzx = ext == "tzx";
	g_tape.offsets = g_tape.tzx ? scan_tzx(g_tape.data) : scan_tap(g_tape.data);
	g_tape.loaded = true;
}

/// Pone `path` en el reproductor de la máquina en marcha (conserva el estado del motor).
static bool tape_insert_file(ZxHandle *h, const std::string &path) {
	auto *const target = dynamic_cast<MachineTypes::MediaTarget *>(h->machine.get());
	if(!target) return false;
	const std::string ext = lower_ext(path);
	Analyser::Static::Media media;
	try {
		if(ext == "tap") media.tapes.push_back(std::make_shared<Storage::Tape::ZXSpectrumTAP>(path));
		else if(ext == "tzx") media.tapes.push_back(std::make_shared<Storage::Tape::TZX>(path));
		else if(ext == "csw") media.tapes.push_back(std::make_shared<Storage::Tape::CSW>(path));
		else return false;
	} catch(...) {
		return false;
	}
	g_tape.last = -1;
	return target->insert_media(media);
}

/// Aplica las opciones del core: carga rápida y motor automático (apagado en pausa).
static void apply_tape_options(ZxHandle *h) {
	if(!h->configurable) return;
	auto options = h->configurable->get_options();
	if(auto *const zx = dynamic_cast<Sinclair::ZXSpectrum::Machine::Options *>(options.get())) {
		zx->quick_load = h->turbo_load;
		zx->automatic_tape_motor_control = !h->tape_paused;
		zx->output = Configurable::Display::RGB;
		h->configurable->set_options(options);
	}
}

extern "C" {

const char *zx_last_error(void) {
	return g_last_error.c_str();
}

ZxHandle *zx_create(const char *rom_dir, int model, const char *media_path, int audio_freq) {
	using Target = Analyser::Static::ZXSpectrum::Target;
	g_last_error.clear();
	g_zx_mouse = ZxMouse();
	zx_ulaplus_active = 0;
	g_tape.clear_media();
	g_tape.recording = false;
	g_tape.rec.clear();

	try {
		const std::string dir = rom_dir ? rom_dir : "";
		const std::string path = media_path ? media_path : "";
		const std::string ext = lower_ext(path);

		if(ext == "nex") {
			std::vector<uint8_t> nex, rom;
			if(!read_file(path, nex)) { g_last_error = "open_failed"; return nullptr; }
			if(!read_file(dir + "/48.rom", rom) || rom.size() < 0x4000) { g_last_error = "missing_roms"; return nullptr; }
			auto h = std::make_unique<ZxHandle>();
			h->next = std::make_unique<nx::NextMachine>(audio_freq);
			h->next->set_rom(rom.data(), rom.size());
			// Los archivos que pida el juego (esxDOS): carpeta "<juego>.files" si existe (la crea el
			// importador de .zip); si no, la carpeta del propio .nex.
			{
				const size_t slash = path.find_last_of("/\\");
				const size_t dot = path.find_last_of('.');
				const std::string files_dir = path.substr(0, dot) + ".files";
				std::error_code ec;
				if(std::filesystem::is_directory(files_dir, ec)) h->next->set_data_dir(files_dir);
				else h->next->set_data_dir(slash == std::string::npos ? std::string(".") : path.substr(0, slash));
			}
			std::string err;
			if(!h->next->load_nex(nex.data(), nex.size(), err)) { g_last_error = err; return nullptr; }
			h->model = ZX_MODEL_NEXT;
			h->next_file = std::move(nex);
			LOGI("Next creada: %s", path.c_str());
			return h.release();
		}

		std::unique_ptr<Target> target;
		bool type_load = false;

		// Snapshots: el archivo define el modelo y el estado.
		if(ext == "z80" || ext == "sna" || ext == "szx") {
			std::unique_ptr<Analyser::Static::Target> t;
			if(ext == "z80") t = load_z80(path);
			else if(ext == "sna") {
				t = Storage::State::SNA::load(path);
				if(!t) t = load_sna128(path);
			}
			else t = Storage::State::SZX::load(path);
			if(!t) {
				// Los .sna de Amstrad CPC empiezan con "MV - SNA": avisar en vez de "dañado".
				std::vector<uint8_t> head;
				const bool cpc = read_file(path, head) && head.size() > 8 && std::memcmp(head.data(), "MV - SNA", 8) == 0;
				g_last_error = cpc ? "cpc_snapshot" : "bad_snapshot";
				return nullptr;
			}
			target.reset(static_cast<Target *>(t.release()));
		} else {
			target = std::make_unique<Target>();
			target->model = Target::Model(std::clamp(model, 0, 5));

			if(ext == "tap") {
				target->media.tapes.push_back(std::make_shared<Storage::Tape::ZXSpectrumTAP>(path));
			} else if(ext == "tzx") {
				target->media.tapes.push_back(std::make_shared<Storage::Tape::TZX>(path));
			} else if(ext == "csw") {
				target->media.tapes.push_back(std::make_shared<Storage::Tape::CSW>(path));
			} else if(ext == "dsk") {
				target->media.disks.push_back(
					std::make_shared<Storage::Disk::DiskImageHolder<Storage::Disk::CPCDSK>>(path));
				target->model = Target::Model::Plus3;
			} else if(!path.empty()) {
				g_last_error = "unsupported_format";
				return nullptr;
			}

			if(!target->media.empty()) {
				// 128K/+2/+3: Enter en el menú elige "Tape Loader"/"Loader".
				// 16K/48K: hay que teclear LOAD "".
				if(target->model <= Target::Model::FortyEightK) type_load = true;
				else target->should_hold_enter = true;
			}
		}

		const ROMMachine::ROMFetcher fetcher = [&dir](const ROM::Request &request) -> ROM::Map {
			ROM::Map map;
			static const std::pair<ROM::Name, const char *> files[] = {
				{ROM::Name::Spectrum48k, "48.rom"},
				{ROM::Name::Spectrum128k, "128.rom"},
				{ROM::Name::SpectrumPlus2, "plus2.rom"},
				{ROM::Name::SpectrumPlus3, "plus3.rom"},
			};
			for(const auto &[name, file] : files) {
				std::vector<uint8_t> data;
				if(read_file(dir + "/" + file, data)) map[name] = std::move(data);
			}
			(void)request;
			return map;
		};

		auto h = std::make_unique<ZxHandle>();
		h->model = int(target->model);
		h->rom_dir = dir;
		h->machine = Sinclair::ZXSpectrum::Machine::create(*target, fetcher);
		if(!h->machine) { g_last_error = "machine_failed"; return nullptr; }

		auto *const raw = h->machine.get();
		h->timed = dynamic_cast<MachineTypes::TimedMachine *>(raw);
		h->keyboard = dynamic_cast<MachineTypes::KeyboardMachine *>(raw);
		h->joysticks = dynamic_cast<MachineTypes::JoystickMachine *>(raw);
		h->resettable = dynamic_cast<MachineTypes::SoftResettable *>(raw);
		h->configurable = dynamic_cast<Configurable::Device *>(raw);
		auto *const scan_producer = h->scan_producer = dynamic_cast<MachineTypes::ScanProducer *>(raw);
		auto *const audio_producer = dynamic_cast<MachineTypes::AudioProducer *>(raw);

		if(!h->timed || !scan_producer) { g_last_error = "machine_failed"; return nullptr; }

		scan_producer->set_scan_target(&h->scan_target);

		if(audio_producer) {
			h->speaker = audio_producer->get_speaker();
			if(h->speaker) {
				h->speaker->set_output_rate(float(audio_freq), 512, true);
				h->speaker->set_delegate(&h->audio);
			}
		}

		zx_set_quickload(h.get(), 1);

		if(type_load && h->keyboard) {
			// LOAD "" en 48K: en modo K la J produce LOAD; Symbol Shift+P, la comilla.
			using namespace Sinclair::ZX::Keyboard;
			double t = 2.5;	// esperar a que el ROM termine de arrancar
			h->add_press(t, {KeyJ});
			h->add_press(t, {KeySymbolShift, KeyP});
			h->add_press(t, {KeySymbolShift, KeyP});
			h->add_press(t, {KeyEnter});
		}

		if(ext == "tap" || ext == "tzx" || ext == "csw") tape_load_state(path);

		LOGI("máquina creada: modelo %d, media '%s'", int(target->model), path.c_str());
		return h.release();
	} catch(ROMMachine::Error) {
		g_last_error = "missing_roms";
	} catch(const std::exception &e) {
		g_last_error = e.what();
	} catch(...) {
		g_last_error = "open_failed";
	}
	LOGI("zx_create falló: %s", g_last_error.c_str());
	return nullptr;
}

void zx_destroy(ZxHandle *h) {
	if(!h) return;
	if(h->pdp) pdp::stop();	// antes de destruir la maquina: reanuda la CPU si estaba detenida
	if(h->next) { h->next->detach_debugger(); delete h; return; }
	if(h->speaker) h->speaker->set_delegate(nullptr);
	h->machine.reset();
	delete h;
}

static int run_machine(ZxHandle *h, double seconds);

static pdp::Host pdp_host(ZxHandle *h) {
	pdp::Host host;
	host.supported = true;	// CLK (hook en el bus) y la Next (parada entre instrucciones)
	host.machine = h->next ? "next" : "zx";
	host.reset = [h] { zx_reset(h); };
	host.emulated_seconds = [h] { return zx_get_emulated_time(h); };
	host.set_key = [h](int key, bool down) { zx_set_key(h, key, down ? 1 : 0); };
	host.set_joy = [h](int mask) { zx_set_joystick(h, mask); };
	host.frame = [h] { return zx_get_framebuffer(h); };
	host.type = [h](const std::string &text) { zx_type(h, text.c_str()); };
	return host;
}

int zx_run(ZxHandle *h, double seconds) {
	if(!h || seconds <= 0.0) return 0;
	if(h->pdp) pdp::pump(pdp_host(h));
	// Detenida por el depurador: no se debe llamar a run_for() (ver zx_debug.h).
	const int frames = zxdbg::g.stopped ? 0 : run_machine(h, seconds);
	if(h->pdp) pdp::pump(pdp_host(h));
	return frames;
}

static int run_machine(ZxHandle *h, double seconds) {
	if(h->next) return h->next->run(seconds);
	if(h->script_pos < h->script.size()) {
		h->clock += seconds;
		while(h->script_pos < h->script.size() && h->script[h->script_pos].at <= h->clock) {
			const auto &step = h->script[h->script_pos++];
			h->keyboard->set_key_state(step.key, step.press);
		}
	}

	// Turbo de carga. El trap de CLK solo acelera la rutina LD-BYTES del ROM; los
	// cargadores propios (casi todos los .tzx: Speedlock, Alkatraz…) cargan a
	// velocidad real. Mientras el motor gira (CLK lo enciende al detectar un bucle
	// de lectura de cinta y lo apaga tras 0,5 s sin lecturas) se emula en tramos
	// hasta gastar ~75% del tick (máx. 25 ms) en tiempo real, con tope ×50 y audio silenciado.
	const bool playing = h->machine->get_tape_is_playing();
	if(!playing) h->turbo_suppressed = false;
	const bool turbo = h->turbo_load && playing && !h->turbo_suppressed;
	if(turbo != h->in_turbo) {
		h->in_turbo = turbo;
		h->audio.set_muted(turbo);
	}
	if(turbo) {
		using Clock = std::chrono::steady_clock;
		const double budget = std::min(seconds * 0.75, 0.025);	// tope: no ahogar la UI
		const auto deadline = Clock::now() + std::chrono::duration<double>(budget);
		const double limit = seconds * 50.0;
		constexpr double Slice = 0.02;
		double done = 0.0;
		// Sin rasterizar los tramos intermedios (solo se muestra un frame por tick y
		// dibujarlos todos es el grueso del costo); el último tramo sí dibuja. No se
		// desconecta el ScanTarget: perdería la cuenta de líneas y la imagen saltaría.
		h->scan_target.set_drawing(false);
		while(done < limit && Clock::now() < deadline && h->machine->get_tape_is_playing() && !zxdbg::g.stopped) {
			h->timed->run_for(Time::Seconds(Slice));
			h->timed->flush_output(MachineTypes::TimedMachine::Output::All);
			done += Slice;
		}
		h->scan_target.set_drawing(true);
		const double tail = std::max(seconds - done, 0.041);	// ≥1 frame completo visible
		if(!zxdbg::g.stopped) h->timed->run_for(Time::Seconds(tail));
		h->emulated += done + tail;
	} else {
		h->timed->run_for(Time::Seconds(seconds));
		h->emulated += seconds;
	}
	h->timed->flush_output(MachineTypes::TimedMachine::Output::All);
	return h->scan_target.take_frames();
}

double zx_get_emulated_time(ZxHandle *h) {
	if(h && h->next) return h->next->emulated_seconds();
	return h ? h->emulated : 0.0;
}

int zx_get_model(ZxHandle *h) {
	return h ? h->model : ZX_MODEL_48K;
}

int zx_is_ulaplus(ZxHandle *h) {
	return (h && !h->next && zx_ulaplus_active) ? 1 : 0;
}

int zx_is_turbo(ZxHandle *h) {
	if(h && h->next) return 0;
	return (h && h->in_turbo) ? 1 : 0;
}

const uint8_t *zx_get_framebuffer(ZxHandle *h) {
	if(h && h->next) return h->next->frame();
	return h ? h->scan_target.front() : nullptr;
}

void zx_set_key(ZxHandle *h, int key, int pressed) {
	if(h && h->next) { h->next->set_key(key, pressed != 0); return; }
	if(!h || !h->keyboard) return;
	if(pressed && h->in_turbo) h->turbo_suppressed = true;
	h->keyboard->set_key_state(uint16_t(key), pressed != 0);
}

void zx_clear_keys(ZxHandle *h) {
	if(h && h->next) { h->next->clear_keys(); return; }
	if(h && h->keyboard) h->keyboard->clear_all_keys();
}

void zx_type(ZxHandle *h, const char *utf8) {
	if(!h || h->next || !h->keyboard || !utf8) return;
	std::wstring w;
	for(const char *p = utf8; *p; ++p) w.push_back(wchar_t(uint8_t(*p)));	// ASCII basta
	h->keyboard->type_string(w);
}

static ZxMouse *mouse_of(ZxHandle *h) {
	if(!h) return nullptr;
	return h->next ? &h->next->mouse() : &g_zx_mouse;
}

void zx_set_mouse_mode(ZxHandle *h, int mode) {
	if(ZxMouse *m = mouse_of(h)) m->mode = mode < 0 || mode > 2 ? 0 : mode;
}

void zx_mouse_move(ZxHandle *h, int dx, int dy) {
	if(ZxMouse *m = mouse_of(h)) m->move(dx, dy);
}

void zx_mouse_buttons(ZxHandle *h, int buttons) {
	if(ZxMouse *m = mouse_of(h)) m->buttons = uint8_t(buttons & 7);
}

void zx_set_joystick(ZxHandle *h, int mask) {
	if(h && h->next) { h->next->set_joystick(mask); return; }
	if(!h || !h->joysticks) return;
	const auto &sticks = h->joysticks->get_joysticks();
	if(sticks.empty()) return;
	auto &stick = *sticks.front();
	using Input = Inputs::Joystick::Input;
	if(mask && h->in_turbo) h->turbo_suppressed = true;
	const int changed = mask ^ h->joy_mask;
	h->joy_mask = mask;
	const std::pair<int, Input::Type> map[] = {
		{ZX_JOY_UP, Input::Up}, {ZX_JOY_DOWN, Input::Down},
		{ZX_JOY_LEFT, Input::Left}, {ZX_JOY_RIGHT, Input::Right},
		{ZX_JOY_FIRE, Input::Fire},
	};
	for(const auto &[bit, type] : map) {
		if(changed & bit) stick.set_input(Input(type), (mask & bit) != 0);
	}
}

int zx_get_audio(ZxHandle *h, int16_t *out, int max_samples) {
	if(h && h->next) return out && max_samples > 0 ? h->next->drain_audio(out, max_samples) : 0;
	return (h && out && max_samples > 0) ? h->audio.drain(out, max_samples) : 0;
}

void zx_reset(ZxHandle *h) {
	if(h) { zxdbg::drain(); zxdbg::g.last_start_pc = -1; zxdbg::g.prefix = 0; }
	if(h && h->next) {
		std::string err;
		h->next->load_nex(h->next_file.data(), h->next_file.size(), err);
		return;
	}
	if(h && h->resettable) h->resettable->soft_reset();
}

void zx_set_tape_playing(ZxHandle *h, int playing) {
	if(h && !h->next) h->machine->set_tape_is_playing(playing != 0);
}

int zx_get_tape_playing(ZxHandle *h) {
	return (h && !h->next && h->machine->get_tape_is_playing()) ? 1 : 0;
}

void zx_set_quickload(ZxHandle *h, int enabled) {
	if(!h || h->next) return;
	h->turbo_load = enabled != 0;
	apply_tape_options(h);
}

// --- Gestor de cintas (doc/TAPE_MANAGER.md) ---

int zx_tape_insert(ZxHandle *h, const char *path) {
	if(!h || h->next || !path) return 0;
	const std::string p = path;
	const std::string ext = lower_ext(p);
	if(ext != "tap" && ext != "tzx" && ext != "csw") return 0;
	if(!tape_insert_file(h, p)) return 0;
	tape_load_state(p);
	return 1;
}

void zx_tape_eject(ZxHandle *h) {
	if(!h || h->next) return;
	// CLK no deja quitar la cinta: se pone una vacía (.tap de 0 bytes = fin de cinta).
	const std::string empty = h->rom_dir + "/.tape_empty.tap";
	{ std::ofstream f(empty, std::ios::binary | std::ios::trunc); }
	h->machine->set_tape_is_playing(false);
	tape_insert_file(h, empty);
	g_tape.clear_media();
}

int zx_tape_seek(ZxHandle *h, int block) {
	if(!h || h->next || !g_tape.loaded) return 0;
	const int total = int(g_tape.offsets.size());
	if(block < 0 || block > total) return 0;
	const bool playing = h->machine->get_tape_is_playing();
	const long start = block == total ? long(g_tape.data.size()) : g_tape.offsets[size_t(block)];
	// CLK abre las cintas por ruta: el recorte (bloques block..fin) va a un archivo temporal.
	// Bloque 0 de un .tzx = el archivo entero; en un .tap el recorte desde 0 es idéntico.
	const long header = g_tape.tzx ? 10 : 0;
	// Dos nombres alternados: CLK todavía tiene abierto el recorte anterior al crear el nuevo.
	h->tape_seek_flip = !h->tape_seek_flip;
	const std::string out = h->rom_dir + (h->tape_seek_flip ? "/.tape_seek1" : "/.tape_seek0") +
		(g_tape.tzx ? ".tzx" : ".tap");
	{
		std::ofstream f(out, std::ios::binary | std::ios::trunc);
		if(!f) return 0;
		if(header) f.write(reinterpret_cast<const char *>(g_tape.data.data()), header);
		f.write(reinterpret_cast<const char *>(g_tape.data.data()) + start, std::streamsize(g_tape.data.size() - size_t(start)));
		if(!f) return 0;
	}
	if(!tape_insert_file(h, out)) return 0;
	g_tape.base = block;
	g_tape.header = header;
	g_tape.base_offset = start;
	h->machine->set_tape_is_playing(playing && !h->tape_paused);
	return 1;
}

int zx_tape_info(ZxHandle *h, int *block, int *total) {
	if(block) *block = 0;
	if(total) *total = 0;
	if(!h || h->next) return 0;
	int flags = 0;
	if(g_tape.any) flags |= ZX_TAPE_INSERTED;
	if(g_tape.loaded) {
		if(block) *block = g_tape.current();
		if(total) *total = int(g_tape.offsets.size());
		if(g_tape.current() >= int(g_tape.offsets.size())) flags |= ZX_TAPE_END;
	}
	if(h->machine->get_tape_is_playing()) flags |= ZX_TAPE_PLAYING;
	if(h->tape_paused) flags |= ZX_TAPE_PAUSED;
	if(g_tape.recording) flags |= ZX_TAPE_RECORDING;
	return flags;
}

void zx_tape_set_paused(ZxHandle *h, int paused) {
	if(!h || h->next) return;
	h->tape_paused = paused != 0;
	apply_tape_options(h);
	h->machine->set_tape_is_playing(!h->tape_paused);
}

void zx_tape_record(ZxHandle *h, int enabled) {
	if(!h || h->next) return;
	g_tape.recording = enabled != 0;
}

int zx_tape_take_recorded(ZxHandle *h, uint8_t *out, int max) {
	if(!h || h->next) return 0;
	if(!out) return int(g_tape.rec.size());
	const int n = std::min(max, int(g_tape.rec.size()));
	// Solo bloques enteros: el lector de Dart añade al archivo lo que recibe.
	int whole = 0;
	while(whole + 2 <= n) {
		const int len = g_tape.rec[size_t(whole)] | (g_tape.rec[size_t(whole) + 1] << 8);
		if(whole + 2 + len > n) break;
		whole += 2 + len;
	}
	std::memcpy(out, g_tape.rec.data(), size_t(whole));
	g_tape.rec.erase(g_tape.rec.begin(), g_tape.rec.begin() + whole);
	return whole;
}

void zx_set_gigascreen(ZxHandle *h, int enabled) {
	if(h && !h->next) h->scan_target.set_gigascreen(enabled != 0);
}

int zx_pdp_start(ZxHandle *h, int port) {
	if(!h) return -1;
	if(h->next) h->next->attach_debugger();	// la máquina de CLK se engancha sola al primer run_for
	const int p = pdp::start(port);
	if(p > 0) h->pdp = true;
	return p;
}

void zx_pdp_stop(ZxHandle *h) {
	if(h && h->pdp) { pdp::stop(); h->pdp = false; }
}

void zx_set_speed(ZxHandle *h, double multiplier) {
	if(h && h->next) { h->next->set_speed(multiplier); return; }
	if(h) h->timed->set_speed_multiplier(multiplier);
}

}	// extern "C"
