// Vídeo, sprites y Copper de la Next.
#include "next_machine.h"

#include <algorithm>
#include <cstring>

namespace nx {

namespace {

constexpr int kLinesPerFrame = 312;

inline uint16_t be16(const uint8_t *p) { return uint16_t(p[0] << 8 | p[1]); }

const uint32_t *rgba_lut() {
	static uint32_t lut[512];
	static bool init = false;
	if(!init) {
		auto ex = [](int v) { return uint32_t((v << 5) | (v << 2) | (v >> 1)); };
		for(int c = 0; c < 512; ++c) {
			const uint32_t r = ex((c >> 6) & 7), g = ex((c >> 3) & 7), b = ex(c & 7);
			lut[c] = 0xFF000000u | (b << 16) | (g << 8) | r;
		}
		init = true;
	}
	return lut;
}

}	// namespace

// ---------------------------------------------------------------------------
// Copper

void NextMachine::copper_run(int cvc, int hc) {
	if(copper_mode_ == 0) return;
	for(int n = 0; n < 64; ++n) {
		const uint16_t w = be16(&copper_ram_[(copper_pc_ & 0x3FF) * 2]);
		if(w & 0x8000) {	// WAIT
			const int v = w & 0x1FF;
			const int h = (w >> 9) & 0x3F;
			if(v >= kLinesPerFrame || h * 8 > 447) return;	// HALT
			if(cvc == v && hc >= h) copper_pc_ = (copper_pc_ + 1) & 0x3FF;
			else return;
		} else {
			const int reg = (w >> 8) & 0x7F;
			if(reg != 0 || (w & 0xFF) != 0) nr_write(uint8_t(reg), uint8_t(w & 0xFF));
			copper_pc_ = (copper_pc_ + 1) & 0x3FF;
		}
	}
}

// ---------------------------------------------------------------------------
// Sprites

void NextMachine::rebuild_sprites() {
	sprites_.clear();
	sprites_dirty_ = false;
	Spr anchor{};
	bool anchor_vis = false;
	for(int i = 0; i < 128; ++i) {
		const uint8_t *a = spr_attr_[i];
		const bool has4 = a[3] & 0x40;
		const bool relative = has4 && ((a[4] >> 6) == 1);
		bool vis = a[3] & 0x80;
		if(relative) vis = vis && anchor_vis;
		else anchor_vis = vis;
		if(!vis) continue;

		uint8_t cur[5];
		int anchor_pattern = 0;
		if(!relative) {
			std::memcpy(cur, a, 5);
		} else {
			const bool arot = anchor.rel_type ? anchor.rotate : false;
			const bool axm = anchor.rel_type ? anchor.xmirror : false;
			const bool aym = anchor.rel_type ? anchor.ymirror : false;
			const int axs = anchor.rel_type ? anchor.xscale : 0;
			const int ays = anchor.rel_type ? anchor.yscale : 0;
			const uint8_t x0 = arot ? a[1] : a[0];
			const uint8_t y0 = arot ? a[0] : a[1];
			const uint8_t x1 = (arot != axm) ? uint8_t(-x0) : x0;
			const uint8_t y1 = aym ? uint8_t(-y0) : y0;
			const int x2 = ((((x1 & 0x80) ? 0x100 : 0) | x1) << axs) & 0x1FF;
			const int y2 = ((((y1 & 0x80) ? 0x100 : 0) | y1) << ays) & 0x1FF;
			const int x3 = (anchor.x + x2) & 0x1FF;
			const int y3 = (anchor.y + y2) & 0x1FF;
			const int paloff = (a[2] & 1) ? ((anchor.paloff + (a[2] >> 4)) & 15) : (a[2] >> 4);
			const bool xm = arot ? (((a[2] >> 2) ^ (a[2] >> 1)) & 1) : ((a[2] >> 3) & 1);
			const bool ym = arot ? (((a[2] >> 3) ^ (a[2] >> 1)) & 1) : ((a[2] >> 2) & 1);
			cur[0] = uint8_t(x3);
			cur[1] = uint8_t(y3);
			if(anchor.rel_type) {
				cur[2] = uint8_t((paloff << 4) | ((axm != xm) << 3) | ((aym != ym) << 2)
					| ((arot != bool((a[2] >> 1) & 1)) << 1) | ((x3 >> 8) & 1));
				cur[4] = uint8_t((anchor.h4 << 7) | (((a[4] >> 5) & 1) << 6) | (axs << 3) | (ays << 1) | ((y3 >> 8) & 1));
			} else {
				cur[2] = uint8_t((paloff << 4) | (a[2] & 0x0E) | ((x3 >> 8) & 1));
				cur[4] = uint8_t((anchor.h4 << 7) | (((a[4] >> 5) & 1) << 6) | (a[4] & 0x1E) | ((y3 >> 8) & 1));
			}
			cur[3] = uint8_t(0x80 | 0x40 | (a[3] & 0x3F));
			anchor_pattern = anchor.pattern;
		}
		const uint8_t ext = (a[3] & 0x40) ? cur[4] : 0;
		Spr s{};
		s.y = ((ext & 1) << 8) | cur[1];
		s.x = ((cur[2] & 1) << 8) | cur[0];
		s.rotate = cur[2] & 2;
		s.ymirror = cur[2] & 4;
		s.xmirror = cur[2] & 8;
		s.paloff = cur[2] >> 4;
		s.h4 = (ext & 0x80) && (a[3] & 0x40);
		const bool n6 = (ext & 0x40) && s.h4;
		s.pattern = ((cur[3] & 0x3F) << 1) | (n6 ? 1 : 0);
		if(relative && (a[4] & 1)) s.pattern = (s.pattern + anchor_pattern) & 0x7F;
		s.yscale = (ext >> 1) & 3;
		s.xscale = (ext >> 3) & 3;
		s.rel_type = (a[4] & 0x20) && (a[3] & 0x40);
		sprites_.push_back(s);
		if(!relative) anchor = s;
	}
}

void NextMachine::render_sprites(int y) {
	for(int x = 0; x < kFbWidth; ++x) spr_row_[x] = -1;
	if(!(nr_[0x15] & 0x01)) return;
	if(sprites_dirty_) rebuild_sprites();
	if(sprites_.empty()) return;

	int cx1, cx2, cy1, cy2;
	const bool over_border = nr_[0x15] & 0x02;
	if(!over_border) {
		cx1 = clip_spr_[0] + 32; cx2 = clip_spr_[1] + 32;
		cy1 = clip_spr_[2] + 32; cy2 = clip_spr_[3] + 32;
	} else if(nr_[0x15] & 0x20) {
		cx1 = clip_spr_[0] * 2; cx2 = clip_spr_[1] * 2 + 1;
		cy1 = clip_spr_[2]; cy2 = clip_spr_[3];
	} else {
		cx1 = 0; cx2 = kFbWidth - 1; cy1 = 0; cy2 = kFbHeight - 1;
	}
	if(y < cy1 || y > cy2) return;
	cx1 = std::max(cx1, 0);
	cx2 = std::min(cx2, kFbWidth - 1);

	const int kind = pal_kind_spr();
	const int transp = nr_[0x4B];
	const bool zero_on_top = nr_[0x15] & 0x40;
	const int count = int(sprites_.size());
	for(int k = 0; k < count; ++k) {
		const Spr &s = sprites_[zero_on_top ? count - 1 - k : k];
		int dy = s.y & 0x1FF;
		if(dy > kFbHeight - 1) dy -= 512;
		const int h = 16 << s.yscale, w = 16 << s.xscale;
		if(y < dy || y >= dy + h) continue;
		int dx = s.x & 0x1FF;
		if(dx > kFbWidth - 1) dx -= 512;
		if(dx + w <= cx1 || dx > cx2) continue;
		const int uy = (y - dy) >> s.yscale;
		const int t = s.h4 ? (transp & 0x0F) : transp;
		for(int ox = 0; ox < w; ++ox) {
			const int fx = dx + ox;
			if(fx < cx1 || fx > cx2) continue;
			const int ux = ox >> s.xscale;
			const int mx = s.xmirror ? 15 - ux : ux;
			const int my = s.ymirror ? 15 - uy : uy;
			const int col = s.rotate ? my : mx;
			const int row = s.rotate ? 15 - mx : my;
			int pix, idx;
			if(s.h4) {
				const uint8_t b = spr_pat_[(s.pattern * 128 + row * 8 + (col >> 1)) & 0x3FFF];
				pix = (col & 1) ? (b & 15) : (b >> 4);
				idx = (s.paloff << 4) + pix;
			} else {
				pix = spr_pat_[((s.pattern >> 1) * 256 + row * 16 + col) & 0x3FFF];
				idx = (pix + (s.paloff << 4)) & 0xFF;
			}
			if(pix == t) continue;
			spr_row_[fx] = int16_t(pal9_[kind][idx]);
		}
	}
}

// ---------------------------------------------------------------------------
// Capas

int16_t NextMachine::ula_pixel(int row, int x) {
	if(nr_[0x68] & 0x80) return -1;
	const int kind = pal_kind_ula();
	const bool ulanext = nr_[0x43] & 0x01;
	int idx;
	if(x >= 32 && x < 288 && row >= 32 && row < 224) {
		const int px = x - 32, py = row - 32;
		if(px < clip_ula_[0] || px > clip_ula_[1] || py < clip_ula_[2] || py > clip_ula_[3]) return -1;
		if(nr_[0x15] & 0x80) {	// LoRes 128x96, 8 bpp
			const int sx = (px + nr_[0x32]) & 255;
			const int sy = (py + nr_[0x33]) % 192;
			const int ly = sy >> 1, lx = sx >> 1;
			const uint8_t *scr = bank16(5);
			const int addr = (ly < 48 ? 128 * ly : 0x2000 + 128 * (ly - 48)) + lx;
			idx = scr[addr];
		} else {
			const int sx = (px + nr_[0x26]) & 255;
			const int sy = (py + nr_[0x27]) % 192;
			const uint8_t *scr = bank16((port_7ffd_ & 8) ? 7 : 5);
			const int tmode = port_ff_ & 7;
			const int pix_addr = ((sy & 0xC0) << 5) | ((sy & 7) << 8) | ((sy & 0x38) << 2) | (sx >> 3);
			if((tmode & 6) == 6) {	// hi-res 512x192 monocromo
				const int hx = px * 2;
				const int col = hx >> 3;
				const int rowbase = pix_addr & ~31;
				const uint8_t b = scr[((col & 1) ? 0x2000 : 0) + rowbase + (col >> 1)];
				const bool on = ((b >> (6 - (hx & 7))) & 3) != 0;
				const int ink = (port_ff_ >> 3) & 7;
				idx = on ? ink : 16 + (7 - ink);
			} else {
				const int base = (tmode == 1) ? 0x2000 : 0;
				const uint8_t bits = scr[base + pix_addr];
				const uint8_t attr = (tmode == 2) ? scr[0x2000 + pix_addr] : scr[base + 0x1800 + (sy >> 3) * 32 + (sx >> 3)];
				const bool on = bits & (0x80 >> (sx & 7));
				if(ulanext) {
					const int mask = nr_[0x42];
					int shift = 0;
					for(int m = mask; m; m >>= 1) shift += m & 1;
					const int ink = attr & mask;
					const int paper = 128 + (shift >= 8 ? 0 : (attr >> shift));
					idx = on ? ink : (paper & 0xFF);
				} else {
					const int bright = (attr & 0x40) ? 8 : 0;
					bool ink_on = on;
					if((attr & 0x80) && (frame_counter_ & 16)) ink_on = !ink_on;
					idx = ink_on ? ((attr & 7) + bright) : (16 + ((attr >> 3) & 7) + bright);
				}
			}
		}
	} else {
		idx = ulanext ? (128 + border_) : (16 + border_);
	}
	const uint16_t c = pal9_[kind][idx & 0xFF];
	if((c >> 1) == nr_[0x14]) return -1;
	return int16_t(c);
}

int16_t NextMachine::tile_pixel(int row, int x, bool &over_ula) {
	const uint8_t ctl = nr_[0x6B];
	if(!(ctl & 0x80)) return -1;
	if(x < clip_tile_[0] * 2 || x > clip_tile_[1] * 2 + 1 || row < clip_tile_[2] || row > clip_tile_[3]) return -1;
	const bool mode80 = ctl & 0x40, noattr = ctl & 0x20, tm512 = ctl & 0x02, text = ctl & 0x08;
	const int scroll_x = ((nr_[0x2F] & 3) << 8) | nr_[0x30];
	const int scroll_y = nr_[0x31];
	const int width = mode80 ? 640 : 320;
	const int wx = ((mode80 ? x * 2 : x) + scroll_x) % width;
	const int wy = (row + scroll_y) % 256;
	const int cols = mode80 ? 80 : 40;
	const int tx = wx >> 3, ty = wy >> 3, ix = wx & 7, iy = wy & 7;

	const uint8_t *map = bank16((nr_[0x6E] & 0x80) ? 7 : 5) + ((nr_[0x6E] & 0x3F) << 8);
	const int off = (ty * cols + tx) * (noattr ? 1 : 2);
	const uint8_t *entry = map + (off & 0x3FFF);
	int code = entry[0];
	const uint8_t attr = noattr ? nr_[0x6C] : entry[1];
	if(tm512) code |= (attr & 1) << 8;
	const uint8_t *tiles = bank16((nr_[0x6F] & 0x80) ? 7 : 5) + ((nr_[0x6F] & 0x3F) << 8);

	bool cat2;
	if(ctl & 0x01) cat2 = true;
	else if(tm512) cat2 = false;
	else cat2 = !(attr & 1);
	over_ula = cat2;

	if(text) return -1;	// modo texto: pendiente
	const bool xm = attr & 8, ym = attr & 4, rot = attr & 2;
	const int mx = xm ? 7 - ix : ix;
	const int my = ym ? 7 - iy : iy;
	const int col = rot ? my : mx;
	const int r = rot ? 7 - mx : my;
	const uint8_t b = tiles[(code * 32 + r * 4 + (col >> 1)) & 0x3FFF];
	const int nib = (col & 1) ? (b & 15) : (b >> 4);
	if(nib == (nr_[0x4C] & 0x0F)) return -1;
	return int16_t(pal9_[pal_kind_tile()][((attr >> 4) << 4) + nib]);
}

int16_t NextMachine::l2_pixel(int row, int x, bool &prio) {
	prio = false;
	if(!l2_enable_) return -1;
	const int mode = (nr_[0x70] >> 4) & 3;
	const int paloff = nr_[0x70] & 15;
	const uint8_t *base = bank16(nr_[0x12]);
	const int kind = pal_kind_l2();
	const int scroll_x = nr_[0x16] | ((nr_[0x71] & 1) << 8);
	const int scroll_y = nr_[0x17];
	int idx;
	if(mode == 0) {
		const int lx = x - 32, ly = row - 32;
		if(lx < 0 || lx > 255 || ly < 0 || ly > 191) return -1;
		if(lx < clip_l2_[0] || lx > clip_l2_[1] || ly < clip_l2_[2] || ly > clip_l2_[3]) return -1;
		const int sx = (lx + scroll_x) & 255;
		const int sy = (ly + scroll_y) % 192;
		idx = (base[sy * 256 + sx] + (paloff << 4)) & 0xFF;
	} else {
		if(x < clip_l2_[0] * 2 || x > clip_l2_[1] * 2 + 1 || row < clip_l2_[2] || row > clip_l2_[3]) return -1;
		const int sy = (row + scroll_y) % 256;
		if(mode == 1) {
			const int sx = (x + scroll_x) % 320;
			idx = (base[sx * 256 + sy] + (paloff << 4)) & 0xFF;
		} else {
			const int hx = (x * 2 + scroll_x) % 640;
			const uint8_t b = base[(hx >> 1) * 256 + sy];
			idx = (paloff << 4) + ((hx & 1) ? (b & 15) : (b >> 4));
		}
	}
	const uint16_t c = pal9_[kind][idx];
	if((c >> 1) == nr_[0x14]) return -1;
	prio = l2_prio_[kind - 2][idx];
	return int16_t(c);
}

// ---------------------------------------------------------------------------
// Composición

void NextMachine::render_chunk(int row, int x0, int x1) {
	enum { S = 0, L = 1, U = 2 };
	static const uint8_t orders[6][3] = {
		{S, L, U}, {L, S, U}, {S, U, L}, {L, U, S}, {U, S, L}, {U, L, S},
	};
	int o = (nr_[0x15] >> 2) & 7;
	if(o > 5) o = 0;
	const uint8_t *ord = orders[o];
	const uint32_t *lut = rgba_lut();
	const uint32_t fallback = lut[(nr_[0x4A] << 1) | ((nr_[0x4A] >> 1) & 1) | (nr_[0x4A] & 1)];
	uint32_t *dst = reinterpret_cast<uint32_t *>(back_.data()) + size_t(row) * kFbWidth;

	for(int x = x0; x < x1; ++x) {
		int16_t layer[3];
		layer[S] = spr_row_[x];
		bool prio;
		layer[L] = l2_pixel(row, x, prio);
		bool over;
		int16_t t = tile_pixel(row, x, over);
		int16_t u = ula_pixel(row, x);
		// Tilemap + ULA forman un solo grupo; el tilemap va debajo o encima según el atributo.
		int16_t g = -1;
		if(t >= 0 && !over) g = t;
		if(u >= 0) g = u;
		if(t >= 0 && over) g = t;
		layer[U] = g;

		int16_t c = -1;
		if(layer[L] >= 0 && prio) c = layer[L];
		else {
			for(int i = 0; i < 3; ++i)
				if(layer[ord[i]] >= 0) { c = layer[ord[i]]; break; }
		}
		dst[x] = c >= 0 ? lut[c] : fallback;
	}
}

void NextMachine::debug_pixel(int row, int x, int out[4]) {
	bool over, prio;
	out[0] = ula_pixel(row, x);
	out[1] = tile_pixel(row, x, over);
	out[2] = l2_pixel(row, x, prio);
	render_sprites(row);
	out[3] = spr_row_[x];
}

void NextMachine::render_line() {
	const int ccvc = (cvc_ + nr_[0x64]) % kLinesPerFrame;
	int row;
	if(cvc_ < 224) row = cvc_ + 32;
	else if(cvc_ >= 280) row = cvc_ - 280;
	else row = -1;
	if(row < 0) {
		copper_run(ccvc, 99);
		return;
	}
	render_sprites(row);
	for(int c = 0; c < 40; ++c) {
		copper_run(ccvc, c - 4);
		render_chunk(row, c * 8, c * 8 + 8);
	}
	copper_run(ccvc, 99);
}

}	// namespace nx
