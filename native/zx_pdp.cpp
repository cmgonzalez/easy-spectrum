// Servidor PDP (fase 1): TCP local + JSON por línea. Protocolo en doc/PDP.md.
#include "zx_pdp.h"
#include "zx_debug.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET sock_t;
static const sock_t BadSock = INVALID_SOCKET;
static void close_sock(sock_t s) { closesocket(s); }
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int sock_t;
static const sock_t BadSock = -1;
static void close_sock(sock_t s) { close(s); }
#endif

namespace pdp {
namespace {

// ---------------------------------------------------------------- servidor (hilo propio)

struct Client { int id; sock_t fd; std::string in; };
struct Inbound { int client; std::string line; };

struct Server {
	std::thread th;
	std::atomic<bool> quit{false};
	sock_t listen_fd = BadSock;
	int port = 0;
	std::mutex mu;
	std::deque<Inbound> inbox;
	std::vector<std::pair<int, std::string>> outbox;	// (cliente | -1 = todos, línea)
	std::vector<Client> clients;						// solo el hilo del servidor
	int next_id = 1;
};

Server *S = nullptr;

void serve(Server *s) {
	char buf[4096];
	while(!s->quit) {
		fd_set rs;
		FD_ZERO(&rs);
		FD_SET(s->listen_fd, &rs);
		int maxfd = int(s->listen_fd);
		for(const auto &c : s->clients) { FD_SET(c.fd, &rs); maxfd = std::max(maxfd, int(c.fd)); }
		timeval tv{0, 2000};
		const int n = select(maxfd + 1, &rs, nullptr, nullptr, &tv);

		if(n > 0) {
			if(FD_ISSET(s->listen_fd, &rs)) {
				const sock_t fd = accept(s->listen_fd, nullptr, nullptr);
				if(fd != BadSock) s->clients.push_back({s->next_id++, fd, {}});
			}
			for(size_t i = 0; i < s->clients.size();) {
				Client &c = s->clients[i];
				bool dead = false;
				if(FD_ISSET(c.fd, &rs)) {
					const int r = recv(c.fd, buf, sizeof buf, 0);
					if(r <= 0) dead = true;
					else {
						c.in.append(buf, size_t(r));
						size_t nl;
						while((nl = c.in.find('\n')) != std::string::npos) {
							std::string line = c.in.substr(0, nl);
							c.in.erase(0, nl + 1);
							if(!line.empty() && line.back() == '\r') line.pop_back();
							if(line.empty()) continue;
							std::lock_guard<std::mutex> lk(s->mu);
							s->inbox.push_back({c.id, std::move(line)});
						}
						if(c.in.size() > (1 << 20)) dead = true;	// línea absurda
					}
				}
				if(dead) { close_sock(c.fd); s->clients.erase(s->clients.begin() + long(i)); }
				else ++i;
			}
		}

		std::vector<std::pair<int, std::string>> out;
		{
			std::lock_guard<std::mutex> lk(s->mu);
			out.swap(s->outbox);
		}
		for(const auto &o : out) {
			const std::string text = o.second + "\n";
			for(auto &c : s->clients) {
				if(o.first >= 0 && o.first != c.id) continue;
				send(c.fd, text.data(), int(text.size()), 0);
			}
		}
	}
	for(auto &c : s->clients) close_sock(c.fd);
	s->clients.clear();
}

void post(int client, const std::string &line) {
	if(!S) return;
	std::lock_guard<std::mutex> lk(S->mu);
	S->outbox.emplace_back(client, line);
}

// ---------------------------------------------------------------- símbolos (.map de z88dk)

struct Sym { uint16_t addr; std::string name; std::string src; };
std::vector<Sym> g_syms;						// ordenado por dirección (mejor nombre primero)
std::map<std::string, uint16_t> g_symmap;

bool lower_eq(const std::string &a, const std::string &b) {
	if(a.size() != b.size()) return false;
	for(size_t i = 0; i < a.size(); ++i) if(tolower((unsigned char)a[i]) != tolower((unsigned char)b[i])) return false;
	return true;
}

int sym_priority(const std::string &n) {	// los marcadores de sección de z88dk pierden frente a los nombres reales
	if(n.size() > 1 && n[0] == '_' && n[1] == '_') return 2;
	if(n.compare(0, 2, "i_") == 0 || n.compare(0, 2, "l_") == 0 || n.compare(0, 2, "s_") == 0) return 1;
	return 0;
}

// Línea: "_name = $5C20 ; addr, public, , modulo, SECCION, archivo:linea". Solo las de tipo addr.
int load_map(const std::string &path) {
	FILE *f = fopen(path.c_str(), "rb");
	if(!f) return -1;
	std::vector<Sym> syms;
	std::map<std::string, uint16_t> names;
	std::string line;
	int ch;
	auto parse = [&](const std::string &l) {
		const size_t eq = l.find(" = $");
		const size_t semi = l.find(';', eq == std::string::npos ? 0 : eq);
		if(eq == std::string::npos || semi == std::string::npos) return;
		const size_t t0 = l.find_first_not_of(' ', semi + 1);
		if(t0 == std::string::npos || l.compare(t0, 5, "addr,") != 0) return;
		std::string name = l.substr(0, eq);
		while(!name.empty() && name.back() == ' ') name.pop_back();
		const unsigned addr = unsigned(strtoul(l.c_str() + eq + 4, nullptr, 16)) & 0xffff;
		std::string src;
		size_t p = t0;
		for(int k = 0; k < 5 && p != std::string::npos; ++k) p = l.find(',', p + 1);	// 5 comas → campo del archivo
		if(p != std::string::npos) { src = l.substr(p + 1); while(!src.empty() && (src[0] == ' ')) src.erase(0, 1); while(!src.empty() && (src.back() == '\r' || src.back() == ' ')) src.pop_back(); }
		syms.push_back({uint16_t(addr), name, src});
		if(!names.count(name)) names[name] = uint16_t(addr);
	};
	while((ch = fgetc(f)) != EOF) {
		if(ch == '\n') { parse(line); line.clear(); }
		else line += char(ch);
	}
	if(!line.empty()) parse(line);
	fclose(f);
	std::stable_sort(syms.begin(), syms.end(), [](const Sym &a, const Sym &b) {
		return a.addr != b.addr ? a.addr < b.addr : sym_priority(a.name) < sym_priority(b.name);
	});
	g_syms.swap(syms);
	g_symmap.swap(names);
	return int(g_syms.size());
}

const Sym *nearest_sym(unsigned addr, unsigned max_off = 0x1000) {
	auto it = std::upper_bound(g_syms.begin(), g_syms.end(), addr, [](unsigned a, const Sym &s) { return a < s.addr; });
	if(it == g_syms.begin()) return nullptr;
	--it;
	while(it != g_syms.begin() && (it - 1)->addr == it->addr) --it;
	return addr - it->addr <= max_off ? &*it : nullptr;
}

std::string sym_for(unsigned addr) {
	const Sym *s = nearest_sym(addr & 0xffff);
	if(!s) return "";
	const unsigned off = (addr & 0xffff) - s->addr;
	char b[16];
	if(!off) return s->name;
	snprintf(b, sizeof b, "+0x%X", off);
	return s->name + b;
}

bool parse_number(const std::string &str, long long &out) {
	const char *p = str.c_str();
	if(!*p) return false;
	int base = 10;
	bool neg = false;
	if(*p == '-') { neg = true; ++p; }
	if(p[0] == '$' || p[0] == '#') { base = 16; ++p; }
	else if(p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) { base = 16; p += 2; }
	char *end = nullptr;
	out = strtoll(p, &end, base);
	if(!(end && *end == 0 && end != p)) return false;
	if(neg) out = -out;
	return true;
}

bool find_sym(const std::string &n, long long &out) {
	auto it = g_symmap.find(n);
	if(it == g_symmap.end()) it = g_symmap.find("_" + n);
	if(it == g_symmap.end()) return false;
	out = it->second;
	return true;
}

// Número, símbolo o símbolo±desplazamiento.
bool parse_value(const std::string &str, long long &out) {
	if(parse_number(str, out)) return true;
	if(find_sym(str, out)) return true;
	const size_t p = str.find_last_of("+-");
	long long off = 0, base = 0;
	if(p != std::string::npos && p > 0 && parse_number(str.substr(p + 1), off) && find_sym(str.substr(0, p), base)) {
		out = str[p] == '+' ? base + off : base - off;
		return true;
	}
	return false;
}

bool parse_cond(std::string s, zxdbg::Cond &c) {
	s.erase(std::remove_if(s.begin(), s.end(), [](char ch) { return isspace((unsigned char)ch); }), s.end());
	size_t pos = s.find_first_of("=!<>&");
	if(pos == std::string::npos || pos == 0) return false;
	zxdbg::CondOp op;
	size_t oplen = 2;
	const std::string two = s.substr(pos, 2);
	if(two == "==") op = zxdbg::C_EQ;
	else if(two == "!=") op = zxdbg::C_NE;
	else if(two == "<=") op = zxdbg::C_LE;
	else if(two == ">=") op = zxdbg::C_GE;
	else { oplen = 1; if(s[pos] == '<') op = zxdbg::C_LT; else if(s[pos] == '>') op = zxdbg::C_GT; else if(s[pos] == '&') op = zxdbg::C_AND; else return false; }
	std::string lhs = s.substr(0, pos);
	long long v = 0;
	if(!parse_value(s.substr(pos + oplen), v)) return false;
	c = zxdbg::Cond();
	c.on = true; c.op = op; c.val = int32_t(v);
	if(lhs[0] == '[') {
		const size_t e = lhs.find(']');
		long long a = 0;
		if(e == std::string::npos || !parse_value(lhs.substr(1, e - 1), a)) return false;
		c.reg = zxdbg::R_NONE; c.mem = int32_t(a & 0xffff); c.word = lhs.size() > e + 1 && tolower(lhs[e + 1]) == 'w';
		return true;
	}
	static const char *names[] = {"pc", "sp", "af", "bc", "de", "hl", "ix", "iy", "a", "f", "b", "c", "d", "e", "h", "l", "i", "r", "iff1", "iff2", "im"};
	for(int i = 0; i < 21; ++i) if(lower_eq(lhs, names[i])) { c.reg = int8_t(i); return true; }
	return false;
}

// ---------------------------------------------------------------- JSON mínimo (objeto plano)

struct Msg {
	std::map<std::string, std::string> kv;	// valor sin comillas
	std::map<std::string, bool> is_str;

	bool parse(const std::string &s) {
		size_t i = 0;
		auto ws = [&] { while(i < s.size() && isspace((unsigned char)s[i])) ++i; };
		auto str = [&](std::string &out) {
			if(i >= s.size() || s[i] != '"') return false;
			++i;
			while(i < s.size() && s[i] != '"') {
				if(s[i] == '\\' && i + 1 < s.size()) {
					++i;
					switch(s[i]) { case 'n': out += '\n'; break; case 't': out += '\t'; break; default: out += s[i]; }
				} else out += s[i];
				++i;
			}
			if(i >= s.size()) return false;
			++i;
			return true;
		};
		ws();
		if(i >= s.size() || s[i++] != '{') return false;
		for(;;) {
			ws();
			if(i < s.size() && s[i] == '}') return true;
			std::string key, val;
			if(!str(key)) return false;
			ws();
			if(i >= s.size() || s[i++] != ':') return false;
			ws();
			bool q = false;
			if(i < s.size() && s[i] == '"') { q = true; if(!str(val)) return false; }
			else while(i < s.size() && s[i] != ',' && s[i] != '}' && !isspace((unsigned char)s[i])) val += s[i++];
			kv[key] = val;
			is_str[key] = q;
			ws();
			if(i < s.size() && s[i] == ',') { ++i; continue; }
			if(i < s.size() && s[i] == '}') return true;
			return false;
		}
	}
	bool has(const char *k) const { return kv.count(k) != 0; }
	std::string get(const char *k) const { auto it = kv.find(k); return it == kv.end() ? std::string() : it->second; }
	bool flag(const char *k) const { const auto v = get(k); return v == "true" || v == "1"; }
	// Números (decimal, 0x1F, $1F), símbolos del .map (_main, game_key+4) y sumas.
	bool num(const char *k, long long &out) const {
		auto it = kv.find(k);
		return it != kv.end() && parse_value(it->second, out);
	}
};

std::string quote(const std::string &s) {
	std::string o = "\"";
	for(const char c : s) {
		if(c == '"' || c == '\\') { o += '\\'; o += c; }
		else if(c == '\n') o += "\\n";
		else o += c;
	}
	return o + "\"";
}

std::string hex16(unsigned v) { char b[16]; snprintf(b, sizeof b, "\"0x%04X\"", v & 0xffff); return b; }

// ---------------------------------------------------------------- comandos (hilo del emulador)

struct Pending { int client; std::string id; };
std::vector<Pending> g_pending;	// respuestas que esperan a la próxima parada ("wait": true)

const char *reason_name(zxdbg::Reason r) {
	switch(r) {
		case zxdbg::Reason::Pause: return "pause";
		case zxdbg::Reason::Breakpoint: return "breakpoint";
		case zxdbg::Reason::Step: return "step";
		case zxdbg::Reason::Until: return "until";
		case zxdbg::Reason::Watch: return "watch";
		case zxdbg::Reason::Crash: return "crash";
		default: return "none";
	}
}

std::string addr_fields(const char *key, unsigned a) {	// "key":"0x1234","key_sym":"_main+3"
	std::string o = std::string("\"") + key + "\":" + hex16(a);
	const std::string sy = sym_for(a);
	if(!sy.empty()) o += std::string(",\"") + key + "_sym\":" + quote(sy);
	return o;
}

std::string state_fields() {
	const auto &g = zxdbg::g;
	if(!g.stopped) return "\"state\":\"running\"";
	std::string o = std::string("\"state\":\"stopped\",\"reason\":\"") + reason_name(g.reason) + "\"," + addr_fields("pc", g.stop_pc);
	if(g.reason == zxdbg::Reason::Watch) {
		char b[80];
		snprintf(b, sizeof b, ",\"value\":%u,\"access\":\"%s\",", g.hit_val, g.hit_write ? "write" : "read");
		o += b + addr_fields("addr", g.hit_addr);
	} else if(g.reason == zxdbg::Reason::Crash) {
		o += std::string(",\"detail\":\"") + g.detail + "\"";
		if(g.from_pc >= 0) o += "," + addr_fields("from", unsigned(g.from_pc));
	}
	return o;
}

std::string flags_text(uint8_t f) {
	std::string s;
	const char *n = "SZ5H3PNC";
	for(int b = 7; b >= 0; --b) s += (f & (1 << b)) ? n[7 - b] : '-';
	return s;
}

std::string regs_json(const zxdbg::Regs &r) {
	std::string o = "{";
	auto add = [&](const char *k, unsigned v) { o += std::string("\"") + k + "\":" + hex16(v) + ","; };
	add("pc", r.pc); add("sp", r.sp); add("af", r.af); add("bc", r.bc); add("de", r.de); add("hl", r.hl);
	add("af2", r.af2); add("bc2", r.bc2); add("de2", r.de2); add("hl2", r.hl2);
	add("ix", r.ix); add("iy", r.iy); add("memptr", r.memptr);
	char b[96];
	snprintf(b, sizeof b, "\"i\":%u,\"r\":%u,\"iff1\":%u,\"iff2\":%u,\"im\":%u,", r.i, r.r, r.iff1, r.iff2, r.im);
	o += b;
	o += "\"flags\":\"" + flags_text(uint8_t(r.af & 0xff)) + "\"}";
	return o;
}

std::string id_json(const std::string &raw) {
	if(raw.empty()) return "null";
	char *end = nullptr;
	strtoll(raw.c_str(), &end, 10);
	return (end && *end == 0) ? raw : quote(raw);
}

void reply(int client, const std::string &id, bool ok, const std::string &fields) {
	std::string o = "{\"id\":" + id_json(id) + ",\"ok\":" + (ok ? "true" : "false");
	if(!fields.empty()) o += "," + fields;
	post(client, o + "}");
}
void fail(int client, const std::string &id, const std::string &why) { reply(client, id, false, "\"error\":" + quote(why)); }

// Tras una acción que hace correr la máquina: con "wait" la respuesta espera a la parada.
void reply_run(int client, const std::string &id, const Msg &m) {
	if(m.flag("wait") && !zxdbg::g.stopped) g_pending.push_back({client, id});
	else reply(client, id, true, state_fields());
}

std::string hex16s(unsigned v) { char b[16]; snprintf(b, sizeof b, "0x%04X", v & 0xffff); return b; }

// Las últimas n instrucciones ejecutadas (la más antigua primero), con símbolo si hay.
std::string history_json(unsigned n) {
	const zxdbg::Core &g = zxdbg::g;
	std::string l = "[";
	for(unsigned i = 0; i < n; ++i) {
		const unsigned pc = g.hist[(g.hpos - n + i) & g.hmask];
		if(i) l += ",";
		const std::string sy = sym_for(pc);
		l += quote(hex16s(pc) + (sy.empty() ? "" : " " + sy));
	}
	return l + "]";
}

void rebuild_watch() {
	zxdbg::Core &g = zxdbg::g;
	memset(g.wmask, 0, sizeof g.wmask);
	for(const auto &w : g.watches)
		for(unsigned i = 0; i < w.len; ++i) g.wmask[uint16_t(w.addr + i)] |= w.kind;
	g.watch_any = !g.watches.empty();
}

void handle(const Host &h, int client, const std::string &line) {
	Msg m;
	if(!m.parse(line)) { fail(client, "", "json invalido"); return; }
	const std::string id = m.get("id");
	const std::string cmd = m.get("cmd");
	zxdbg::Core &g = zxdbg::g;

	if(cmd == "hello") {
		reply(client, id, true, "\"protocol\":\"pdp/1\",\"machine\":" + quote(h.machine) +
			",\"debug\":" + (h.supported && zxdbg::attached() ? "true" : "false") + "," + state_fields());
		return;
	}
	if(!h.supported) { fail(client, id, "depuracion no soportada en esta maquina"); return; }
	if(!zxdbg::attached()) { fail(client, id, "maquina no iniciada"); return; }

	long long a = 0, n = 0;
	if(cmd == "status") {
		char b[96];
		snprintf(b, sizeof b, ",\"emulated\":%.3f,\"breakpoints\":%d", h.emulated_seconds ? h.emulated_seconds() : 0.0, g.bp_count);
		reply(client, id, true, state_fields() + b);
	} else if(cmd == "pause") {
		if(!g.stopped) g.pause_req = true;
		reply_run(client, id, m);
	} else if(cmd == "resume" || cmd == "run") {
		if(g.stopped) {
			if(m.num("until", a)) { g.until_addr = int(a & 0xffff); g.until_sp = -1; }
			zxdbg::resume();
		}
		reply_run(client, id, m);
	} else if(cmd == "step") {
		if(g.stopped) { g.step_req = true; zxdbg::resume(); }
		else g.step_req = true;
		reply_run(client, id, m);
	} else if(cmd == "next") {
		if(!g.stopped) { fail(client, id, "next requiere la maquina detenida"); return; }
		const uint16_t pc = g.stop_pc;
		const uint8_t op = g.t.peek(g.t.ctx, pc);
		int len = 0, sp = -1;
		if(op == 0xCD || (op & 0xC7) == 0xC4) { len = 3; sp = g.regs.sp; }
		else if((op & 0xC7) == 0xC7) { len = 1; sp = g.regs.sp; }
		else if(op == 0x76) len = 1;
		else if(op == 0xED) {
			const uint8_t o2 = g.t.peek(g.t.ctx, uint16_t(pc + 1));
			if((o2 & 0xF4) == 0xB0) len = 2;
		}
		if(len) { g.until_addr = (pc + len) & 0xffff; g.until_sp = sp; }
		else g.step_req = true;
		zxdbg::resume();
		reply_run(client, id, m);
	} else if(cmd == "regs") {
		zxdbg::Regs r;
		if(g.stopped) r = g.regs; else g.t.regs(g.t.ctx, &r);
		reply(client, id, true, std::string("\"live\":") + (g.stopped ? "false" : "true") + ",\"regs\":" + regs_json(r));
	} else if(cmd == "mem") {
		if(!m.num("addr", a)) { fail(client, id, "falta addr"); return; }
		n = 16; m.num("len", n);
		if(n < 1 || n > 4096) { fail(client, id, "len fuera de rango (1-4096)"); return; }
		std::string hx;
		char b[4];
		for(long long i = 0; i < n; ++i) { snprintf(b, sizeof b, "%02X", g.t.peek(g.t.ctx, uint16_t(a + i))); hx += b; }
		reply(client, id, true, "\"addr\":" + hex16(unsigned(a)) + ",\"len\":" + std::to_string(n) + ",\"data\":\"" + hx + "\"");
	} else if(cmd == "poke") {
		if(!m.num("addr", a)) { fail(client, id, "falta addr"); return; }
		std::vector<uint8_t> bytes;
		if(m.has("data") && m.is_str["data"]) {
			const std::string d = m.get("data");
			if(d.size() % 2) { fail(client, id, "data: hex de longitud par"); return; }
			for(size_t i = 0; i < d.size(); i += 2) bytes.push_back(uint8_t(strtol(d.substr(i, 2).c_str(), nullptr, 16)));
		} else if(m.num("value", n)) bytes.push_back(uint8_t(n));
		else { fail(client, id, "falta data (hex) o value"); return; }
		for(size_t i = 0; i < bytes.size(); ++i) g.t.poke(g.t.ctx, uint16_t(a + (long long)i), bytes[i]);
		reply(client, id, true, "\"written\":" + std::to_string(bytes.size()));
	} else if(cmd == "break") {
		if(!m.num("addr", a)) { fail(client, id, "falta addr (numero o simbolo)"); return; }
		a &= 0xffff;
		if(m.has("cond")) {
			zxdbg::Cond c;
			if(!parse_cond(m.get("cond"), c)) { fail(client, id, "cond invalida (ej: a==5, [0x9000]>=3, hl&0x80)"); return; }
			g.bp_cond[uint16_t(a)] = c;
		} else g.bp_cond.erase(uint16_t(a));
		if(!g.bp[a]) { g.bp[a] = 1; ++g.bp_count; }
		reply(client, id, true, addr_fields("addr", unsigned(a)));
	} else if(cmd == "unbreak") {
		if(m.get("addr") == "all") { memset(g.bp, 0, sizeof g.bp); g.bp_count = 0; g.bp_cond.clear(); }
		else if(m.num("addr", a)) { a &= 0xffff; if(g.bp[a]) { g.bp[a] = 0; --g.bp_count; } g.bp_cond.erase(uint16_t(a)); }
		else { fail(client, id, "falta addr (o \"all\")"); return; }
		reply(client, id, true, "\"breakpoints\":" + std::to_string(g.bp_count));
	} else if(cmd == "breaks") {
		std::string l = "[";
		for(int i = 0; i < 65536; ++i) if(g.bp[i]) {
			if(l.size() > 1) l += ",";
			std::string t = hex16s(unsigned(i));
			const std::string sy = sym_for(unsigned(i));
			if(!sy.empty()) t += " " + sy;
			if(g.bp_cond.count(uint16_t(i))) t += " [cond]";
			l += quote(t);
		}
		reply(client, id, true, "\"breakpoints\":" + l + "]");
	} else if(cmd == "watch") {
		if(!m.num("addr", a)) { fail(client, id, "falta addr (numero o simbolo)"); return; }
		zxdbg::WatchEntry w;
		w.addr = uint16_t(a);
		n = 1; m.num("len", n);
		if(n < 1 || n > 65535) { fail(client, id, "len fuera de rango"); return; }
		w.len = uint16_t(n);
		const std::string t = m.has("type") ? m.get("type") : "w";
		w.kind = 0;
		if(t.find('r') != std::string::npos) w.kind |= 1;
		if(t.find('w') != std::string::npos) w.kind |= 2;
		if(!w.kind) { fail(client, id, "type: r, w o rw"); return; }
		if(m.num("value", n)) { w.has_val = true; w.val = uint8_t(n); }
		if(m.has("cond") && !parse_cond(m.get("cond"), w.cond)) { fail(client, id, "cond invalida"); return; }
		g.watches.push_back(w);
		rebuild_watch();
		reply(client, id, true, "\"watches\":" + std::to_string(g.watches.size()));
	} else if(cmd == "unwatch") {
		if(m.get("addr") == "all") g.watches.clear();
		else if(m.num("addr", a)) {
			g.watches.erase(std::remove_if(g.watches.begin(), g.watches.end(), [&](const zxdbg::WatchEntry &w) { return w.addr == uint16_t(a); }), g.watches.end());
		} else { fail(client, id, "falta addr (o \"all\")"); return; }
		rebuild_watch();
		reply(client, id, true, "\"watches\":" + std::to_string(g.watches.size()));
	} else if(cmd == "watches") {
		std::string l = "[";
		for(const auto &w : g.watches) {
			if(l.size() > 1) l += ",";
			char b[96];
			snprintf(b, sizeof b, "{\"len\":%u,\"type\":\"%s%s\"", w.len, (w.kind & 1) ? "r" : "", (w.kind & 2) ? "w" : "");
			l += std::string(b) + "," + addr_fields("addr", w.addr) + "}";
		}
		reply(client, id, true, "\"watches\":" + l + "]");
	} else if(cmd == "history") {
		n = 32; m.num("n", n);
		n = std::min<long long>(std::min<long long>(n, 4096), g.hcount);
		reply(client, id, true, "\"history\":" + history_json(unsigned(n)) + ",\"recorded\":" + std::to_string(g.hcount));
	} else if(cmd == "catch") {
		const std::string on = m.get("on");
		g.catch_reset = on.find("reset") != std::string::npos || on == "all";
		g.catch_nmi = on.find("nmi") != std::string::npos || on == "all";
		g.catch_dihalt = on.find("dihalt") != std::string::npos || on == "all";
		g.catch_rom = on.find("rom") != std::string::npos;
		g.catch_any = g.catch_reset || g.catch_nmi || g.catch_dihalt || g.catch_rom;
		std::string l;
		auto add = [&](bool f, const char *nm) { if(f) { if(!l.empty()) l += ","; l += nm; } };
		add(g.catch_reset, "reset"); add(g.catch_nmi, "nmi"); add(g.catch_rom, "rom"); add(g.catch_dihalt, "dihalt");
		reply(client, id, true, "\"catch\":" + quote(l));
	} else if(cmd == "crash") {
		if(!g.stopped) { fail(client, id, "la maquina no esta detenida"); return; }
		std::string st = "[";
		for(int i = 0; i < 8; ++i) {
			const uint16_t at = uint16_t(g.regs.sp + i * 2);
			const unsigned w = g.t.peek(g.t.ctx, at) | (unsigned(g.t.peek(g.t.ctx, uint16_t(at + 1))) << 8);
			if(i) st += ",";
			st += quote(hex16s(w) + (sym_for(w).empty() ? "" : " " + sym_for(w)));
		}
		reply(client, id, true, state_fields() + ",\"regs\":" + regs_json(g.regs) + ",\"history\":" +
			history_json(std::min<unsigned>(24, g.hcount)) + ",\"stack\":" + st + "]");
	} else if(cmd == "load_map") {
		const int cnt = load_map(m.get("path"));
		if(cnt < 0) { fail(client, id, "no se pudo abrir el .map"); return; }
		reply(client, id, true, "\"symbols\":" + std::to_string(cnt));
	} else if(cmd == "sym") {
		const std::string q = m.get("q");
		if(q.empty()) { fail(client, id, "falta q (simbolo o direccion)"); return; }
		if(!parse_value(q, a)) { fail(client, id, "simbolo desconocido: " + q); return; }
		const Sym *sy = nearest_sym(unsigned(a & 0xffff));
		reply(client, id, true, addr_fields("addr", unsigned(a & 0xffff)) + (sy ? ",\"src\":" + quote(sy->src) : std::string()));
	} else if(cmd == "symbols") {
		const std::string flt = m.get("filter");
		n = 100; m.num("limit", n);
		std::string l = "[";
		long long cnt = 0;
		for(const auto &sy : g_syms) {
			if(!flt.empty()) {
				std::string a2 = sy.name, b2 = flt;
				for(auto &ch : a2) ch = char(tolower((unsigned char)ch));
				for(auto &ch : b2) ch = char(tolower((unsigned char)ch));
				if(a2.find(b2) == std::string::npos) continue;
			}
			if(cnt++ >= n) break;
			if(l.size() > 1) l += ",";
			l += quote(hex16s(sy.addr) + " " + sy.name);
		}
		reply(client, id, true, "\"symbols\":" + l + "],\"total\":" + std::to_string(g_syms.size()));
	} else if(cmd == "get") {
		if(!m.num("addr", a)) { fail(client, id, "falta addr (numero o simbolo)"); return; }
		n = 1; m.num("len", n);
		if(n < 1 || n > 4) { fail(client, id, "len 1-4 (usa mem para mas)"); return; }
		unsigned long long v = 0;
		for(long long i = n - 1; i >= 0; --i) v = (v << 8) | g.t.peek(g.t.ctx, uint16_t(a + i));
		reply(client, id, true, addr_fields("addr", unsigned(a & 0xffff)) + ",\"value\":" + std::to_string(v));
	} else if(cmd == "reset") {
		zxdbg::drain();
		g_pending.clear();
		if(h.reset) h.reset();
		reply(client, id, true, state_fields());
	} else {
		fail(client, id, "comando desconocido: " + cmd);
	}
}

}  // namespace

// ---------------------------------------------------------------- API

int start(int port) {
	if(S) stop();
#ifdef _WIN32
	WSADATA wsa;
	WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
	const sock_t fd = socket(AF_INET, SOCK_STREAM, 0);
	if(fd == BadSock) return -1;
	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof yes);
	sockaddr_in addr{};
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons(uint16_t(port));
	if(bind(fd, (sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 4) != 0) { close_sock(fd); return -1; }
	socklen_t len = sizeof addr;
	getsockname(fd, (sockaddr *)&addr, &len);

	S = new Server;
	S->listen_fd = fd;
	S->port = ntohs(addr.sin_port);
	S->th = std::thread(serve, S);
	zxdbg::hist_init(1u << 16);
	zxdbg::g.hist_on = true;
	zxdbg::g.armed = true;
	return S->port;
}

void stop() {
	if(!S) return;
	zxdbg::g.armed = false;
	zxdbg::g.hist_on = false;
	zxdbg::g.watch_any = false;
	zxdbg::g.watches.clear();
	zxdbg::drain();
	S->quit = true;
	S->th.join();
	close_sock(S->listen_fd);
	delete S;
	S = nullptr;
	g_pending.clear();
}

bool running() { return S != nullptr; }

void pump(const Host &host) {
	if(!S) return;
	std::deque<Inbound> in;
	{
		std::lock_guard<std::mutex> lk(S->mu);
		in.swap(S->inbox);
	}
	for(const auto &msg : in) handle(host, msg.client, msg.line);

	if(zxdbg::g.event_pending) {
		zxdbg::g.event_pending = false;
		for(const auto &p : g_pending) reply(p.client, p.id, true, state_fields());
		g_pending.clear();
		post(-1, "{\"event\":\"stopped\"," + state_fields() + "}");
	}
}

}  // namespace pdp
