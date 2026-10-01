// Máquina ZX Spectrum Next (solo para ejecutar archivos .nex, sin NextZXOS).
// Escrita a partir de la documentación pública del hardware (wiki de SpecNext) y usando
// como referencia de consulta el driver BSD de MAME; no contiene código copiado de emuladores GPL.
#pragma once
#include "z80n.h"
#include "../zx_mouse.h"

#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

namespace nx {

constexpr int kFbWidth = 320;
constexpr int kFbHeight = 256;

// Generador AY-3-8910 (uno de los tres de TurboSound).
struct Ay {
	uint8_t reg[16] = {};
	uint8_t selected = 0;
	int tone_cnt[3] = {}, tone_out[3] = {1, 1, 1};
	int noise_cnt = 0;
	uint32_t lfsr = 1;
	int noise_out = 1;
	int env_cnt = 0, env_pos = 0;
	bool env_holding = false;
	int env_vol = 0;
	double step_acc = 0.0;

	void reset();
	void write_reg(uint8_t r, uint8_t v);
	void tick();	// un paso de 1/8 del reloj del AY
	// Nivel instantáneo (0..1) de cada canal A,B,C.
	void levels(float &a, float &b, float &c) const;
};

class NextMachine final : public Z80Bus {
public:
	explicit NextMachine(int audio_rate);
	~NextMachine();

	// Carpeta del host que hace de tarjeta SD para las llamadas esxDOS (RST 8). Vacía = sin archivos.
	void set_data_dir(const std::string &dir);

	// ROM de 16K (48K BASIC): la Next sin NextZXOS la mapea en $0000-$3FFF.
	bool set_rom(const uint8_t *data, size_t size);

	// Carga un .nex y deja la CPU lista para ejecutarlo. Devuelve false y `error` si falla.
	bool load_nex(const uint8_t *data, size_t size, std::string &error);

	void reset();

	// Avanza `seconds` de tiempo real; devuelve los frames completados.
	int run(double seconds);

	const uint8_t *frame() const { return front_.data(); }
	int drain_audio(int16_t *out, int max_samples);

	void set_key(int key, bool pressed);
	void clear_keys();
	void set_joystick(int mask);
	ZxMouse &mouse() { return mouse_; }
	void set_speed(double multiplier) { speed_multiplier_ = multiplier; }
	double emulated_seconds() const { return emulated_; }
	int cpu_speed() const { return cpu_speed_; }	// 0..3 = 3,5 / 7 / 14 / 28 MHz
	Z80N &cpu() { return cpu_; }
	uint8_t peek(uint16_t addr) { return read(addr); }
	uint8_t next_reg(uint8_t r) const { return nr_[r]; }
	uint64_t total_instructions() const { return instr_count_; }
	// Depuración: color de cada capa (ULA, tilemap, Layer 2, sprite) en un píxel; -1 = transparente.
	void debug_pixel(int row, int x, int out[4]);
	uint16_t debug_pal(int kind, int idx) const { return pal9_[kind][idx]; }
	bool trace_regs = false;

	// Z80Bus
	uint8_t read(uint16_t addr) override { return rdp_[addr >> 13][addr & 0x1FFF]; }
	void write(uint16_t addr, uint8_t value) override {
		uint8_t *p = wrp_[addr >> 13];
		if(p) p[addr & 0x1FFF] = value;
	}
	uint8_t in(uint16_t port) override;
	void out(uint16_t port, uint8_t value) override;
	void nextreg(uint8_t reg, uint8_t value) override { nr_write(reg, value); }
	uint8_t int_vector() override;
	void reti_executed() override;

private:
	// --- memoria ---
	std::vector<uint8_t> ram_;	// 2 MB = 256 páginas de 8K
	uint8_t rom_[0x4000];
	uint8_t *rdp_[8];
	uint8_t *wrp_[8];
	uint8_t mmu_[8];
	uint8_t port_7ffd_ = 0, port_dffd_ = 0;
	bool l2_wr_en_ = false, l2_rd_en_ = false, l2_shadow_map_ = false, l2_enable_ = false;
	uint8_t l2_segment_ = 0;
	void remap();
	uint8_t *page(int p) { return ram_.data() + size_t(p & 0xFF) * 0x2000; }
	uint8_t *bank16(int b) { return ram_.data() + size_t(b & 0x7F) * 0x4000; }

	// --- esxDOS ---
	std::string data_dir_, esx_cwd_;
	std::vector<FILE *> esx_files_ = std::vector<FILE *>(16, nullptr);
	bool esx_call();
	uint16_t read16(uint16_t a) { return uint16_t(read(a) | (read(uint16_t(a + 1)) << 8)); }
	int cpu_step();

	// --- CPU ---
	Z80N cpu_;
	int cpu_speed_ = 0;
	uint64_t instr_count_ = 0;

	// --- NextRegs ---
	uint8_t nr_[256];
	uint8_t nr_select_ = 0;
	void nr_write(uint8_t reg, uint8_t v);
	uint8_t nr_read(uint8_t reg);
	void set_defaults();

	// --- paletas (0 ULA, 1 Layer2, 2 sprites, 3 tilemap; ×2 por la segunda paleta) ---
	uint16_t pal9_[8][256];
	uint32_t rgba_[8][256];
	bool l2_prio_[2][256];
	uint8_t pal_index_ = 0;
	int pal_sub_ = 0;
	uint8_t pal_stored_ = 0;
	void pal_write(uint16_t c9, bool prio);
	void pal_set(int kind, int idx, uint16_t c9, bool prio);
	int pal_kind_ula() const { return (nr_[0x43] & 0x02) ? 1 : 0; }
	int pal_kind_l2() const { return 2 + ((nr_[0x43] & 0x04) ? 1 : 0); }
	int pal_kind_spr() const { return 4 + ((nr_[0x43] & 0x08) ? 1 : 0); }
	int pal_kind_tile() const { return 6 + ((nr_[0x6B] & 0x10) ? 1 : 0); }

	// --- clip windows (x1,x2,y1,y2) e índices de escritura ---
	uint8_t clip_l2_[4], clip_spr_[4], clip_ula_[4], clip_tile_[4];
	uint8_t clip_idx_[4] = {};

	// --- sprites ---
	uint8_t spr_pat_[0x4000];
	uint8_t spr_attr_[128][8];
	int spr_attr_idx_ = 0;	// (sprite << 3) | byte
	int spr_pat_idx_ = 0;
	int mirror_sprite_ = 0;
	struct Spr {
		int x, y;
		bool rotate, xmirror, ymirror, h4;
		int paloff, pattern, xscale, yscale;
		bool rel_type;
	};
	std::vector<Spr> sprites_;
	bool sprites_dirty_ = true;
	void rebuild_sprites();
	void render_sprites(int y);
	int16_t spr_row_[kFbWidth];

	// --- copper ---
	uint8_t copper_ram_[0x800];
	int copper_addr_ = 0;	// puntero de escritura
	uint8_t copper_store_ = 0;
	int copper_mode_ = 0;
	int copper_pc_ = 0;
	void copper_run(int cvc, int hc);

	// --- DMA (zxnDMA) ---
	struct Dma {
		bool enabled = false, zilog = false;
		bool a_to_b = true;
		uint16_t a_start = 0, b_start = 0, len = 0;
		uint16_t a_ptr = 0, b_ptr = 0, counter = 0;
		int a_mode = 1, b_mode = 1;	// 0 dec, 1 inc, 2 fijo
		bool a_io = false, b_io = false;
		int a_cyc = 2, b_cyc = 2;
		int mode = 1;	// 0 byte, 1 continuo, 2 ráfaga
		uint8_t prescaler = 0;
		bool autorestart = false;
		bool transferred = false;
		// análisis de bytes de parámetros
		int follow[8];
		int nfollow = 0, follow_pos = 0;
		int cur_reg = -1;
		int read_mask = 0x7F, read_pos = 0;
		int64_t next_ok = 0;
	} dma_;
	void dma_write(uint8_t v, bool zilog);
	uint8_t dma_read();
	void dma_command(uint8_t cmd);
	int dma_transfer_byte();	// devuelve ticks de 28 MHz consumidos

	// --- interrupciones ---
	bool int_hw_mode_ = false;
	int int_pulse_ticks_ = 0;
	uint16_t int_pending_ = 0, int_service_ = 0;
	void raise_int(int source);
	void update_int_line();

	// --- vídeo ---
	std::vector<uint8_t> back_, front_;
	int cvc_ = 0;	// línea actual: 0 = primera línea de papel; 312 líneas
	int frame_counter_ = 0;
	int completed_frames_ = 0;
	uint8_t border_ = 0;
	uint8_t port_ff_ = 0;	// modos Timex
	void render_line();
	void render_chunk(int row, int x0, int x1);
	int16_t ula_pixel(int row, int x);
	int16_t tile_pixel(int row, int x, bool &over_ula);
	int16_t l2_pixel(int row, int x, bool &prio);

	// --- teclado / mandos ---
	uint8_t key_rows_[8];
	uint8_t joy_ = 0;
	ZxMouse mouse_;
	uint8_t kempston() const;

	// --- audio ---
	int audio_rate_;
	Ay ay_[3];
	int ay_selected_ = 0;
	uint8_t dac_[4];
	bool beeper_ = false;
	double audio_acc_ = 0.0;
	std::vector<int16_t> audio_;
	size_t audio_read_ = 0;
	void gen_audio(double seconds);

	// --- temporización ---
	double speed_multiplier_ = 1.0;
	double pending_ = 0.0;
	double emulated_ = 0.0;
	int64_t budget_ = 0;	// ticks de 28 MHz disponibles
	int ticks_per_t() const { return 8 >> cpu_speed_; }
	void run_line();
};

}	// namespace nx
