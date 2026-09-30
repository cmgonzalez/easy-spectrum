#include "single_instance.h"

#include <iterator>

namespace {

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), out.data(), n);
  return out;
}

std::string Narrow(const std::wstring& s) {
  if (s.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), int(s.size()), out.data(), n, nullptr, nullptr);
  return out;
}

BOOL CALLBACK FindMainWindow(HWND hwnd, LPARAM result) {
  if (GetPropW(hwnd, kMainWindowProp)) {
    *reinterpret_cast<HWND*>(result) = hwnd;
    return FALSE;
  }
  return TRUE;
}

}  // namespace

std::vector<std::string> AbsolutizePaths(std::vector<std::string> args) {
  for (size_t i = 0; i < args.size(); i++) {
    if (args[i].rfind("--", 0) == 0) {
      if (args[i] == "--model") i++;
      continue;
    }
    const std::wstring path = Widen(args[i]);
    wchar_t full[MAX_PATH * 4];
    const DWORD n = GetFullPathNameW(path.c_str(), DWORD(std::size(full)), full, nullptr);
    if (n > 0 && n < std::size(full)) args[i] = Narrow(full);
  }
  return args;
}

bool ForwardToRunningInstance(const std::vector<std::string>& args) {
  HWND target = nullptr;
  EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&target));
  if (!target) return false;

  std::string payload;
  for (const auto& a : args) {
    if (!payload.empty()) payload += '\n';
    payload += a;
  }
  COPYDATASTRUCT data = {};
  data.dwData = kOpenArgsMagic;
  data.cbData = DWORD(payload.size());
  data.lpData = payload.data();
  DWORD_PTR ignored = 0;
  SendMessageTimeoutW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                      SMTO_ABORTIFHUNG, 5000, &ignored);

  if (IsIconic(target)) ShowWindow(target, SW_RESTORE);
  SetForegroundWindow(target);
  return true;
}

bool DecodeOpenArgs(const COPYDATASTRUCT* data, std::vector<std::string>* args) {
  if (!data || data->dwData != kOpenArgsMagic) return false;
  const std::string payload(static_cast<const char*>(data->lpData), data->cbData);
  args->clear();
  size_t start = 0;
  while (start <= payload.size() && !payload.empty()) {
    const size_t end = payload.find('\n', start);
    args->push_back(payload.substr(start, end == std::string::npos ? std::string::npos : end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return true;
}
