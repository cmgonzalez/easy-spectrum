#include "native_menu.h"

#include <flutter/standard_method_codec.h>

#include <string>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), int(utf8.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), int(utf8.size()), out.data(), n);
  return out;
}

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  return it == map.end() || it->second.IsNull() ? nullptr : &it->second;
}

bool Flag(const EncodableMap& map, const char* key, bool fallback = false) {
  const auto* v = Field(map, key);
  return v ? std::get<bool>(*v) : fallback;
}

}  // namespace

NativeMenu::NativeMenu(flutter::BinaryMessenger* messenger, HWND hwnd)
    : hwnd_(hwnd) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "cl.easysoft.easyspectrum/menu",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setMenu") {
      const auto& menus = std::get<EncodableList>(*call.arguments());
      if (in_menu_loop_) {
        pending_ = menus;
      } else {
        Apply(menus);
      }
      result->Success();
    } else if (call.method_name() == "setVisible") {
      visible_ = std::get<bool>(*call.arguments());
      Attach();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

NativeMenu::~NativeMenu() {
  if (bar_ && !visible_) DestroyMenu(bar_);  // si está puesta, la destruye la ventana
}

// Cada elemento: {label, id, enabled, checked, radio, separator, children}.
// El texto admite "\t" para el atajo alineado a la derecha y "&" para la letra de Alt.
HMENU NativeMenu::Build(const EncodableList& items, bool bar) {
  HMENU menu = bar ? CreateMenu() : CreatePopupMenu();
  for (const auto& value : items) {
    const auto& item = std::get<EncodableMap>(value);
    if (Flag(item, "separator")) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    std::wstring label = Widen(std::get<std::string>(*Field(item, "label")));
    MENUITEMINFOW info = {sizeof(info)};
    info.fMask = MIIM_STRING | MIIM_FTYPE | MIIM_STATE;
    info.fType = MFT_STRING;
    info.dwTypeData = label.data();
    if (Flag(item, "radio")) info.fType |= MFT_RADIOCHECK;
    if (Flag(item, "checked")) info.fState |= MFS_CHECKED;
    if (!Flag(item, "enabled", true)) info.fState |= MFS_DISABLED;
    if (const auto* children = Field(item, "children")) {
      info.fMask |= MIIM_SUBMENU;
      info.hSubMenu = Build(std::get<EncodableList>(*children), false);
    } else if (const auto* id = Field(item, "id")) {
      info.fMask |= MIIM_ID;
      info.wID = UINT(id->LongValue());
    }
    InsertMenuItemW(menu, GetMenuItemCount(menu), TRUE, &info);
  }
  return menu;
}

void NativeMenu::Apply(const EncodableList& menus) {
  HMENU old = bar_;
  bar_ = Build(menus, true);
  Attach();
  if (old) DestroyMenu(old);
}

void NativeMenu::Attach() {
  SetMenu(hwnd_, visible_ ? bar_ : nullptr);
  DrawMenuBar(hwnd_);
}

std::optional<LRESULT> NativeMenu::HandleMessage(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_COMMAND:
      // HIWORD 0 y sin control = opción de menú.
      if (HIWORD(wparam) == 0 && lparam == 0) {
        channel_->InvokeMethod("select",
                               std::make_unique<EncodableValue>(int32_t(LOWORD(wparam))));
        return 0;
      }
      break;
    case WM_SYSCOMMAND:
      // Alt solo (lparam 0) es el fuego del joystick: no debe llevar el foco a la barra.
      // Alt + letra sigue abriendo el menú correspondiente.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam == 0) return 0;
      break;
    case WM_ENTERMENULOOP:
      in_menu_loop_ = true;
      channel_->InvokeMethod("menuLoop", std::make_unique<EncodableValue>(true));
      break;
    case WM_EXITMENULOOP:
      in_menu_loop_ = false;
      if (pending_) {
        Apply(*pending_);
        pending_.reset();
      }
      channel_->InvokeMethod("menuLoop", std::make_unique<EncodableValue>(false));
      break;
  }
  return std::nullopt;
}
