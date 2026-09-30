// Emulación mínima de esxDOS (RST $08) contra una carpeta del host.
// Muchos .nex cargan sus datos con F_OPEN/F_READ; sin NextZXOS hay que atender esas llamadas.
#include "next_machine.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <vector>

namespace nx {

namespace fs = std::filesystem;

namespace {

enum Err : uint8_t { kNotFound = 5, kBadName = 7, kBadHandle = 9, kNoSpace = 18 };

std::string lower(std::string s) {
	for(auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
	return s;
}

// Busca `name` dentro de `dir` ignorando mayúsculas (los .nex suelen venir de Windows/Mac).
bool find_ci(const fs::path &dir, const std::string &name, fs::path &out) {
	std::error_code ec;
	const fs::path direct = dir / name;
	if(fs::exists(direct, ec)) { out = direct; return true; }
	const std::string want = lower(name);
	for(const auto &e : fs::directory_iterator(dir, ec)) {
		if(lower(e.path().filename().string()) == want) { out = e.path(); return true; }
	}
	return false;
}

}	// namespace

void NextMachine::set_data_dir(const std::string &dir) {
	data_dir_ = dir;
	esx_cwd_.clear();
}

// Resuelve una ruta de esxDOS dentro de data_dir_ sin salir de ella. `must_exist` = false permite
// crear el último componente (F_OPEN con modo de escritura).
static bool resolve(const std::string &root, const std::string &cwd, std::string path, bool must_exist,
					std::string &result) {
	if(root.empty()) return false;
	std::replace(path.begin(), path.end(), '\\', '/');
	if(path.size() >= 2 && path[1] == ':') path.erase(0, 2);	// "C:"
	std::vector<std::string> parts;
	std::string joined = (!path.empty() && path[0] == '/') ? path : (cwd.empty() ? "" : cwd + "/") + path;
	size_t pos = 0;
	while(pos <= joined.size()) {
		size_t next = joined.find('/', pos);
		if(next == std::string::npos) next = joined.size();
		const std::string seg = joined.substr(pos, next - pos);
		if(seg == "..") { if(!parts.empty()) parts.pop_back(); }
		else if(!seg.empty() && seg != ".") parts.push_back(seg);
		pos = next + 1;
	}
	fs::path cur = root;
	for(size_t i = 0; i < parts.size(); ++i) {
		fs::path found;
		const bool last = i + 1 == parts.size();
		if(find_ci(cur, parts[i], found)) cur = found;
		else if(last && !must_exist) cur = cur / parts[i];
		else return false;
	}
	result = cur.string();
	return true;
}

bool NextMachine::esx_call() {
	const uint16_t ret = read16(cpu_.SP);
	const uint8_t fn = read(ret);
	auto &c = cpu_;
	auto fail = [&](uint8_t code) { c.A = code; c.F |= 0x01; };
	auto ok = [&]() { c.F &= uint8_t(~0x01); };
	auto read_name = [&]() {
		std::string s;
		const uint16_t p = c.IX ? c.IX : c.HL();
		for(int i = 0; i < 255; ++i) {
			const uint8_t b = read(uint16_t(p + i));
			if(!b) break;
			s.push_back(char(b));
		}
		return s;
	};
	auto file_for = [&](uint8_t h) -> FILE * {
		return (h < esx_files_.size()) ? esx_files_[h] : nullptr;
	};

	switch(fn) {
		case 0x88:	// M_DOSVERSION
			c.A = 0; c.B = 0; c.C = 0; c.D = 0; c.E = 0;
			ok();
			break;
		case 0x89:	// M_GETSETDRV
			if(c.A == 0) c.A = 'C';
			ok();
			break;
		case 0x9A: {	// F_OPEN
			const std::string name = read_name();
			const uint8_t mode = c.B;
			const bool write = mode & 0x0E;
			std::string path;
			if(data_dir_.empty() || !resolve(data_dir_, esx_cwd_, name, !write, path)) { fail(kNotFound); break; }
			std::error_code ec;
			if((mode & 0x0F) == 0x04 && fs::exists(path, ec)) { fail(kNotFound); break; }	// CREATE_NEW
			const char *fm = write ? ((mode & 0x08) ? "r+b" : "w+b") : "rb";
			if(write && (mode & 0x08) && !fs::exists(path, ec)) fm = "w+b";
			FILE *f = std::fopen(path.c_str(), fm);
			if(!f) { fail(kNotFound); break; }
			int h = -1;
			for(size_t i = 1; i < esx_files_.size(); ++i) if(!esx_files_[i]) { h = int(i); break; }
			if(h < 0) { std::fclose(f); fail(kNoSpace); break; }
			esx_files_[h] = f;
			c.A = uint8_t(h);
			ok();
			break;
		}
		case 0x9B: {	// F_CLOSE
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			std::fclose(f);
			esx_files_[c.A] = nullptr;
			ok();
			break;
		}
		case 0x9C: ok(); break;	// F_SYNC
		case 0x9D: {	// F_READ
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			const uint16_t dest = c.IX ? c.IX : c.HL();
			uint16_t want = c.BC();
			std::vector<uint8_t> buf(want);
			const size_t got = want ? std::fread(buf.data(), 1, want, f) : 0;
			for(size_t i = 0; i < got; ++i) write(uint16_t(dest + i), buf[i]);
			c.setBC(uint16_t(got));
			ok();
			break;
		}
		case 0x9E: {	// F_WRITE
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			const uint16_t src = c.IX ? c.IX : c.HL();
			const uint16_t n = c.BC();
			std::vector<uint8_t> buf(n);
			for(uint16_t i = 0; i < n; ++i) buf[i] = read(uint16_t(src + i));
			const size_t put = n ? std::fwrite(buf.data(), 1, n, f) : 0;
			c.setBC(uint16_t(put));
			ok();
			break;
		}
		case 0x9F: {	// F_SEEK: BCDE = desplazamiento; modo en IXL (o L)
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			const int mode = (c.IX <= 2 && c.IX != 0) ? c.IX : (c.IX ? (c.IX & 3) : (c.L & 3));
			const long off = long((uint32_t(c.B) << 24) | (uint32_t(c.C) << 16) | (uint32_t(c.D) << 8) | c.E);
			if(mode == 0) std::fseek(f, off, SEEK_SET);
			else if(mode == 1) std::fseek(f, off, SEEK_CUR);
			else std::fseek(f, -off, SEEK_CUR);
			const uint32_t pos = uint32_t(std::ftell(f));
			c.B = uint8_t(pos >> 24); c.C = uint8_t(pos >> 16); c.D = uint8_t(pos >> 8); c.E = uint8_t(pos);
			ok();
			break;
		}
		case 0xA0: {	// F_FGETPOS
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			const uint32_t pos = uint32_t(std::ftell(f));
			c.B = uint8_t(pos >> 24); c.C = uint8_t(pos >> 16); c.D = uint8_t(pos >> 8); c.E = uint8_t(pos);
			ok();
			break;
		}
		case 0xA1: {	// F_FSTAT: buffer de 11 bytes en IX/HL, tamaño en los 4 últimos
			FILE *f = file_for(c.A);
			if(!f) { fail(kBadHandle); break; }
			const long cur = std::ftell(f);
			std::fseek(f, 0, SEEK_END);
			const uint32_t size = uint32_t(std::ftell(f));
			std::fseek(f, cur, SEEK_SET);
			const uint16_t p = c.IX ? c.IX : c.HL();
			for(int i = 0; i < 11; ++i) write(uint16_t(p + i), 0);
			for(int i = 0; i < 4; ++i) write(uint16_t(p + 7 + i), uint8_t(size >> (8 * i)));
			ok();
			break;
		}
		case 0xA8: {	// F_GETCWD
			const uint16_t p = c.IX ? c.IX : c.HL();
			const std::string s = "/" + esx_cwd_;
			for(size_t i = 0; i <= s.size(); ++i) write(uint16_t(p + i), i < s.size() ? uint8_t(s[i]) : 0);
			ok();
			break;
		}
		case 0xA9: {	// F_CHDIR
			const std::string name = read_name();
			std::string path;
			if(data_dir_.empty() || !resolve(data_dir_, esx_cwd_, name, true, path)) { fail(kNotFound); break; }
			std::error_code ec;
			if(!fs::is_directory(path, ec)) { fail(kNotFound); break; }
			esx_cwd_ = fs::relative(path, data_dir_, ec).generic_string();
			if(esx_cwd_ == ".") esx_cwd_.clear();
			ok();
			break;
		}
		default:
			fail(kNotFound);
			break;
	}
	// RET tras el byte de función: el llamador sigue en ret + 1.
	c.SP = uint16_t(c.SP + 2);
	c.PC = uint16_t(ret + 1);
	return true;
}

}	// namespace nx
