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
	// Números: decimal, 0x1F, $1F o #1F.
	bool num(const char *k, long long &out) const {
		auto it = kv.find(k);
		if(it == kv.end() || it->second.empty()) return false;
		const char *p = it->second.c_str();
		int base = 10;
		if(p[0] == '$' || p[0] == '#') { base = 16; ++p; }
		else if(p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) { base = 16; p += 2; }
		char *end = nullptr;
		out = strtoll(p, &end, base);
		return end && *end == 0 && end != p;
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
		default: return "none";
	}
}

std::string state_fields() {
	const auto &g = zxdbg::g;
	if(g.stopped)
		return std::string("\"state\":\"stopped\",\"reason\":\"") + reason_name(g.reason) + "\",\"pc\":" + hex16(g.stop_pc);
	return "\"state\":\"running\"";
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
		if(!m.num("addr", a)) { fail(client, id, "falta addr"); return; }
		a &= 0xffff;
		if(!g.bp[a]) { g.bp[a] = 1; ++g.bp_count; }
		reply(client, id, true, "\"addr\":" + hex16(unsigned(a)));
	} else if(cmd == "unbreak") {
		if(m.get("addr") == "all") { memset(g.bp, 0, sizeof g.bp); g.bp_count = 0; }
		else if(m.num("addr", a)) { a &= 0xffff; if(g.bp[a]) { g.bp[a] = 0; --g.bp_count; } }
		else { fail(client, id, "falta addr (o \"all\")"); return; }
		reply(client, id, true, "\"breakpoints\":" + std::to_string(g.bp_count));
	} else if(cmd == "breaks") {
		std::string l = "[";
		for(int i = 0; i < 65536; ++i) if(g.bp[i]) { if(l.size() > 1) l += ","; l += hex16(unsigned(i)); }
		reply(client, id, true, "\"breakpoints\":" + l + "]");
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
	zxdbg::g.armed = true;
	return S->port;
}

void stop() {
	if(!S) return;
	zxdbg::g.armed = false;
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
