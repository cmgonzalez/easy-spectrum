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
#include <cstring>
#include <fstream>
#include <memory>
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

	void end_scan() override {
		if(!data_ptr_ || !data_length_) return;
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
				// Frame completo → publicar.
				{
					std::lock_guard lock(fb_mutex_);
					front_ = work_;
				}
				++frames_;
				// Ajustar la línea superior del papel (estable tras el primer frame).
				if(frame_min_data_line_ != INT32_MAX) {
					if(!v_calibrated_ || frame_min_data_line_ != paper_top_line_) {
						paper_top_line_ = frame_min_data_line_;
						v_calibrated_ = true;
					}
				}
				frame_min_data_line_ = INT32_MAX;
			} break;
			case Event::EndVerticalRetrace:
				line_ = 0;
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

	std::array<uint32_t, FbW * FbH> work_{}, front_{}, snapshot_{};
	std::mutex fb_mutex_;
};

// ---------------------------------------------------------------------------
// Audio: ring buffer int16 alimentado por el delegate del Speaker (otro hilo).
// ---------------------------------------------------------------------------
class AudioRing: public Outputs::Speaker::Speaker::Delegate {
public:
	explicit AudioRing(size_t capacity) : buf_(capacity) {}

	void speaker_did_complete_samples(Outputs::Speaker::Speaker &, const std::vector<int16_t> &buffer) override {
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

}	// namespace

// ---------------------------------------------------------------------------

struct ZxHandle {
	std::unique_ptr<Sinclair::ZXSpectrum::Machine> machine;
	MachineTypes::TimedMachine *timed = nullptr;
	MachineTypes::KeyboardMachine *keyboard = nullptr;
	MachineTypes::JoystickMachine *joysticks = nullptr;
	MachineTypes::SoftResettable *resettable = nullptr;
	Configurable::Device *configurable = nullptr;
	Outputs::Speaker::Speaker *speaker = nullptr;

	SoftScanTarget scan_target;
	AudioRing audio{48000 * 2};	// ~0.5 s estéreo a 48 kHz
	int joy_mask = 0;

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

extern "C" {

const char *zx_last_error(void) {
	return g_last_error.c_str();
}

ZxHandle *zx_create(const char *rom_dir, int model, const char *media_path, int audio_freq) {
	using Target = Analyser::Static::ZXSpectrum::Target;
	g_last_error.clear();

	try {
		const std::string dir = rom_dir ? rom_dir : "";
		const std::string path = media_path ? media_path : "";
		const std::string ext = lower_ext(path);

		std::unique_ptr<Target> target;
		bool type_load = false;

		// Snapshots: el archivo define el modelo y el estado.
		if(ext == "z80" || ext == "sna" || ext == "szx") {
			std::unique_ptr<Analyser::Static::Target> t;
			if(ext == "z80") t = Storage::State::Z80::load(path);
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
		h->machine = Sinclair::ZXSpectrum::Machine::create(*target, fetcher);
		if(!h->machine) { g_last_error = "machine_failed"; return nullptr; }

		auto *const raw = h->machine.get();
		h->timed = dynamic_cast<MachineTypes::TimedMachine *>(raw);
		h->keyboard = dynamic_cast<MachineTypes::KeyboardMachine *>(raw);
		h->joysticks = dynamic_cast<MachineTypes::JoystickMachine *>(raw);
		h->resettable = dynamic_cast<MachineTypes::SoftResettable *>(raw);
		h->configurable = dynamic_cast<Configurable::Device *>(raw);
		auto *const scan_producer = dynamic_cast<MachineTypes::ScanProducer *>(raw);
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
	if(h->speaker) h->speaker->set_delegate(nullptr);
	h->machine.reset();
	delete h;
}

int zx_run(ZxHandle *h, double seconds) {
	if(!h || seconds <= 0.0) return 0;
	if(h->script_pos < h->script.size()) {
		h->clock += seconds;
		while(h->script_pos < h->script.size() && h->script[h->script_pos].at <= h->clock) {
			const auto &step = h->script[h->script_pos++];
			h->keyboard->set_key_state(step.key, step.press);
		}
	}
	h->timed->run_for(Time::Seconds(seconds));
	h->timed->flush_output(MachineTypes::TimedMachine::Output::All);
	return h->scan_target.take_frames();
}

const uint8_t *zx_get_framebuffer(ZxHandle *h) {
	return h ? h->scan_target.front() : nullptr;
}

void zx_set_key(ZxHandle *h, int key, int pressed) {
	if(h && h->keyboard) h->keyboard->set_key_state(uint16_t(key), pressed != 0);
}

void zx_clear_keys(ZxHandle *h) {
	if(h && h->keyboard) h->keyboard->clear_all_keys();
}

void zx_type(ZxHandle *h, const char *utf8) {
	if(!h || !h->keyboard || !utf8) return;
	std::wstring w;
	for(const char *p = utf8; *p; ++p) w.push_back(wchar_t(uint8_t(*p)));	// ASCII basta
	h->keyboard->type_string(w);
}

void zx_set_joystick(ZxHandle *h, int mask) {
	if(!h || !h->joysticks) return;
	const auto &sticks = h->joysticks->get_joysticks();
	if(sticks.empty()) return;
	auto &stick = *sticks.front();
	using Input = Inputs::Joystick::Input;
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
	return (h && out && max_samples > 0) ? h->audio.drain(out, max_samples) : 0;
}

void zx_reset(ZxHandle *h) {
	if(h && h->resettable) h->resettable->soft_reset();
}

void zx_set_tape_playing(ZxHandle *h, int playing) {
	if(h) h->machine->set_tape_is_playing(playing != 0);
}

int zx_get_tape_playing(ZxHandle *h) {
	return (h && h->machine->get_tape_is_playing()) ? 1 : 0;
}

void zx_set_quickload(ZxHandle *h, int enabled) {
	if(!h || !h->configurable) return;
	auto options = h->configurable->get_options();
	if(auto *const zx = dynamic_cast<Sinclair::ZXSpectrum::Machine::Options *>(options.get())) {
		zx->quick_load = enabled != 0;
		zx->automatic_tape_motor_control = true;
		zx->output = Configurable::Display::RGB;
		h->configurable->set_options(options);
	}
}

void zx_set_speed(ZxHandle *h, double multiplier) {
	if(h) h->timed->set_speed_multiplier(multiplier);
}

}	// extern "C"
