#include "native_menu.h"

#include <flutter/standard_method_codec.h>

#include <cwctype>
#include <string>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// Colores del Spectrum. Texto en blanco brillante; la opción marcada, en cian como la
// barra del menú del 128K; el arcoíris, el de su cabecera.
constexpr COLORREF kBack = RGB(0, 0, 0);
constexpr COLORREF kText = RGB(255, 255, 255);
constexpr COLORREF kHighlight = RGB(0, 215, 215);
constexpr COLORREF kHighlightText = RGB(0, 0, 0);
constexpr COLORREF kDisabled = RGB(110, 110, 110);
constexpr COLORREF kSeparator = RGB(70, 70, 70);
constexpr COLORREF kRainbow[] = {RGB(215, 0, 0), RGB(215, 215, 0), RGB(0, 215, 0),
                                 RGB(0, 215, 215)};

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

// Letra de Alt ("&x"; "&&" es un "&" literal), en mayúscula; 0 si no tiene.
wchar_t Mnemonic(const std::wstring& text) {
  for (size_t i = 0; i + 1 < text.size(); i++) {
    if (text[i] != L'&') continue;
    if (text[i + 1] != L'&') return wchar_t(towupper(text[i + 1]));
    i++;
  }
  return 0;
}

void Fill(HDC dc, const RECT& rc, COLORREF color) {
  SetDCBrushColor(dc, color);
  FillRect(dc, &rc, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
}

void DrawLines(HDC dc, const POINT* points, int count, COLORREF color, int width) {
  HPEN pen = CreatePen(PS_SOLID, width, color);
  HGDIOBJ old = SelectObject(dc, pen);
  ::Polyline(dc, points, count);
  SelectObject(dc, old);
  DeleteObject(pen);
}

// Ancho de las franjas del arcoíris (en px a 96 dpi) y su inclinación: 4 franjas más el
// corrimiento de la inclinación y un margen.
constexpr int kStripe = 8;
constexpr int kRainbowWidth = 4 * kStripe + 12 + 8;

}  // namespace

NativeMenu::NativeMenu(flutter::BinaryMessenger* messenger, HWND hwnd)
    : hwnd_(hwnd) {
  // Modo oscuro de la aplicación (API no documentada de uxtheme, la que usan el Bloc de
  // notas y compañía): bordes, sombra y flechas de desplazamiento de los menús en oscuro.
  // Si no existe (Windows viejo), los menús se ven igual salvo el borde.
  if (HMODULE ux = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    using SetPreferredAppMode = int(WINAPI*)(int);
    using FlushMenuThemes = void(WINAPI*)();
    if (auto set = reinterpret_cast<SetPreferredAppMode>(
            GetProcAddress(ux, MAKEINTRESOURCEA(135)))) {
      set(2);  // ForceDark
    }
    if (auto flush = reinterpret_cast<FlushMenuThemes>(
            GetProcAddress(ux, MAKEINTRESOURCEA(136)))) {
      flush();
    }
  }

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
  if (font_) DeleteObject(font_);
}

// Cada elemento: {label, id, enabled, checked, radio, separator, children}.
// El texto admite "\t" para el atajo alineado a la derecha y "&" para la letra de Alt.
HMENU NativeMenu::Build(const EncodableList& items, bool bar, Items& store) {
  HMENU menu = bar ? CreateMenu() : CreatePopupMenu();
  auto add = [&](std::unique_ptr<Item> item, MENUITEMINFOW& info) {
    info.fMask |= MIIM_FTYPE | MIIM_DATA;
    info.fType |= MFT_OWNERDRAW;
    info.dwItemData = reinterpret_cast<ULONG_PTR>(item.get());
    store.push_back(std::move(item));
    InsertMenuItemW(menu, GetMenuItemCount(menu), TRUE, &info);
  };
  for (const auto& value : items) {
    const auto& entry = std::get<EncodableMap>(value);
    auto item = std::make_unique<Item>();
    item->bar = bar;
    MENUITEMINFOW info = {sizeof(info)};
    if (Flag(entry, "separator")) {
      item->separator = true;
      info.fType = MFT_SEPARATOR;
      add(std::move(item), info);
      continue;
    }
    const std::wstring label = Widen(std::get<std::string>(*Field(entry, "label")));
    const size_t tab = label.find(L'\t');
    item->text = label.substr(0, tab);
    if (tab != std::wstring::npos) item->shortcut = label.substr(tab + 1);
    item->radio = Flag(entry, "radio");
    info.fMask = MIIM_STATE;
    if (Flag(entry, "checked")) info.fState |= MFS_CHECKED;
    if (!Flag(entry, "enabled", true)) info.fState |= MFS_DISABLED;
    if (const auto* children = Field(entry, "children")) {
      item->submenu = true;
      info.fMask |= MIIM_SUBMENU;
      info.hSubMenu = Build(std::get<EncodableList>(*children), false, store);
    } else if (const auto* id = Field(entry, "id")) {
      info.fMask |= MIIM_ID;
      info.wID = UINT(id->LongValue());
    }
    add(std::move(item), info);
  }
  if (bar) {
    // Arcoíris al final de la barra, pegado a la derecha (no se puede elegir).
    auto item = std::make_unique<Item>();
    item->bar = item->rainbow = true;
    MENUITEMINFOW info = {sizeof(info)};
    info.fMask = MIIM_STATE;
    info.fType = MFT_RIGHTJUSTIFY;
    info.fState = MFS_DISABLED;
    add(std::move(item), info);
  }
  // Fondo negro de la barra y de los desplegables (lo que no cubren las opciones).
  MENUINFO mi = {sizeof(mi)};
  mi.fMask = MIM_BACKGROUND;
  mi.hbrBack = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  SetMenuInfo(menu, &mi);
  return menu;
}

void NativeMenu::Apply(const EncodableList& menus) {
  HMENU old = bar_;
  Items store;
  bar_ = Build(menus, true, store);
  Attach();
  if (old) DestroyMenu(old);
  items_ = std::move(store);  // los datos del menú viejo viven hasta destruirlo
}

void NativeMenu::Attach() {
  SetMenu(hwnd_, visible_ ? bar_ : nullptr);
  DrawMenuBar(hwnd_);
}

HFONT NativeMenu::Font(UINT dpi) {
  if (font_ && font_dpi_ == dpi) return font_;
  if (font_) DeleteObject(font_);
  NONCLIENTMETRICSW ncm = {sizeof(ncm)};
  SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0, dpi);
  font_ = CreateFontIndirectW(&ncm.lfMenuFont);
  font_dpi_ = dpi;
  return font_;
}

void NativeMenu::Measure(MEASUREITEMSTRUCT* mis) {
  const auto* item = reinterpret_cast<const Item*>(mis->itemData);
  const UINT dpi = GetDpiForWindow(hwnd_);
  auto px = [dpi](int v) { return MulDiv(v, int(dpi), 96); };
  const int bar_height = GetSystemMetricsForDpi(SM_CYMENU, dpi);
  if (item->rainbow) {
    mis->itemWidth = px(kRainbowWidth);
    mis->itemHeight = bar_height;
    return;
  }
  if (item->separator) {
    mis->itemWidth = 0;
    mis->itemHeight = px(9);
    return;
  }
  HDC dc = GetDC(hwnd_);
  HGDIOBJ old = SelectObject(dc, Font(dpi));
  RECT text = {}, shortcut = {};
  DrawTextW(dc, item->text.c_str(), -1, &text, DT_SINGLELINE | DT_CALCRECT);
  if (!item->shortcut.empty()) {
    DrawTextW(dc, item->shortcut.c_str(), -1, &shortcut,
              DT_SINGLELINE | DT_CALCRECT | DT_NOPREFIX);
  }
  SelectObject(dc, old);
  ReleaseDC(hwnd_, dc);
  if (item->bar) {
    mis->itemWidth = text.right + px(16);
    mis->itemHeight = bar_height;
    return;
  }
  int width = px(28) + text.right + px(28);
  if (shortcut.right > 0) width += px(32) + shortcut.right;
  // Windows suma el ancho de la marca a las opciones owner-draw de los desplegables.
  width -= GetSystemMetricsForDpi(SM_CXMENUCHECK, dpi) - 1;
  mis->itemWidth = UINT(width > 0 ? width : 1);
  mis->itemHeight = text.bottom + px(12);
}

void NativeMenu::Draw(const DRAWITEMSTRUCT* dis) {
  const auto* item = reinterpret_cast<const Item*>(dis->itemData);
  const UINT dpi = GetDpiForWindow(hwnd_);
  auto px = [dpi](int v) { return MulDiv(v, int(dpi), 96); };
  HDC dc = dis->hDC;
  const RECT rc = dis->rcItem;
  const UINT state = dis->itemState;
  const bool disabled = (state & (ODS_DISABLED | ODS_GRAYED)) != 0;
  const bool selected = !disabled && (state & (ODS_SELECTED | ODS_HOTLIGHT)) != 0;

  Fill(dc, rc, selected ? kHighlight : kBack);

  if (item->rainbow) {
    const int w = px(kStripe), h = rc.bottom - rc.top, slant = px(12);
    int x = rc.right - px(8) - 4 * w - slant;
    HGDIOBJ old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
    HGDIOBJ old_brush = SelectObject(dc, GetStockObject(DC_BRUSH));
    for (COLORREF color : kRainbow) {
      SetDCBrushColor(dc, color);
      const POINT p[] = {{x + slant, rc.top}, {x + slant + w, rc.top}, {x + w, rc.top + h},
                         {x, rc.top + h}};
      Polygon(dc, p, 4);
      x += w;
    }
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    return;
  }

  if (item->separator) {
    const int y = (rc.top + rc.bottom) / 2;
    Fill(dc, {rc.left + px(8), y, rc.right - px(8), y + 1}, kSeparator);
    return;
  }

  const COLORREF fg = disabled ? kDisabled : selected ? kHighlightText : kText;
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, fg);
  HGDIOBJ old_font = SelectObject(dc, Font(dpi));
  const UINT prefix = (state & ODS_NOACCEL) ? DT_HIDEPREFIX : 0;

  if (item->bar) {
    RECT r = rc;
    DrawTextW(dc, item->text.c_str(), -1, &r, DT_SINGLELINE | DT_VCENTER | DT_CENTER | prefix);
    SelectObject(dc, old_font);
    return;
  }

  RECT r = rc;
  r.left += px(28);
  DrawTextW(dc, item->text.c_str(), -1, &r, DT_SINGLELINE | DT_VCENTER | prefix);
  if (!item->shortcut.empty()) {
    r = rc;
    r.right -= px(28);
    DrawTextW(dc, item->shortcut.c_str(), -1, &r,
              DT_SINGLELINE | DT_VCENTER | DT_RIGHT | DT_NOPREFIX);
  }
  SelectObject(dc, old_font);

  const int cy = (rc.top + rc.bottom) / 2;
  if (state & ODS_CHECKED) {
    const int cx = rc.left + px(14);
    if (item->radio) {
      const int d = px(3);
      HGDIOBJ old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
      HGDIOBJ old_brush = SelectObject(dc, GetStockObject(DC_BRUSH));
      SetDCBrushColor(dc, fg);
      Ellipse(dc, cx - d, cy - d, cx + d + 1, cy + d + 1);
      SelectObject(dc, old_brush);
      SelectObject(dc, old_pen);
    } else {
      const POINT p[] = {{cx - px(4), cy}, {cx - px(1), cy + px(3)}, {cx + px(4), cy - px(3)}};
      DrawLines(dc, p, 3, fg, px(2));
    }
  }
  if (item->submenu) {
    const int x = rc.right - px(14);
    const POINT p[] = {{x - px(2), cy - px(4)}, {x + px(2), cy}, {x - px(2), cy + px(4)}};
    DrawLines(dc, p, 3, fg, px(1) > 0 ? px(1) : 1);
    // Sin esto, Windows pinta encima su flecha (negra, invisible sobre el fondo).
    ExcludeClipRect(dc, rc.left, rc.top, rc.right, rc.bottom);
  }
}

// Las opciones owner-draw no tienen texto para Windows: la letra de Alt se busca aquí.
std::optional<LRESULT> NativeMenu::MenuChar(wchar_t ch, HMENU menu) {
  const wchar_t key = wchar_t(towupper(ch));
  const int count = GetMenuItemCount(menu);
  for (int i = 0; i < count; i++) {
    MENUITEMINFOW info = {sizeof(info)};
    info.fMask = MIIM_DATA | MIIM_STATE;
    if (!GetMenuItemInfoW(menu, UINT(i), TRUE, &info) || !info.dwItemData) continue;
    if (info.fState & MFS_DISABLED) continue;
    const auto* item = reinterpret_cast<const Item*>(info.dwItemData);
    if (Mnemonic(item->text) == key) return MAKELRESULT(i, MNC_EXECUTE);
  }
  return std::nullopt;
}

// La línea de 1 px bajo la barra la pinta Windows en blanco; se tapa de negro.
void NativeMenu::PaintBarLine() {
  MENUBARINFO mbi = {sizeof(mbi)};
  if (!GetMenuBarInfo(hwnd_, OBJID_MENU, 0, &mbi)) return;
  RECT window;
  GetWindowRect(hwnd_, &window);
  const RECT line = {mbi.rcBar.left - window.left, mbi.rcBar.bottom - window.top,
                     mbi.rcBar.right - window.left, mbi.rcBar.bottom - window.top + 1};
  HDC dc = GetWindowDC(hwnd_);
  Fill(dc, line, kBack);
  ReleaseDC(hwnd_, dc);
}

std::optional<LRESULT> NativeMenu::HandleMessage(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MEASUREITEM: {
      auto* mis = reinterpret_cast<MEASUREITEMSTRUCT*>(lparam);
      if (mis->CtlType != ODT_MENU) break;
      Measure(mis);
      return TRUE;
    }
    case WM_DRAWITEM: {
      const auto* dis = reinterpret_cast<const DRAWITEMSTRUCT*>(lparam);
      if (dis->CtlType != ODT_MENU) break;
      Draw(dis);
      return TRUE;
    }
    case WM_MENUCHAR:
      return MenuChar(wchar_t(LOWORD(wparam)), reinterpret_cast<HMENU>(lparam));
    case WM_NCPAINT:
    case WM_NCACTIVATE: {
      if (!visible_ || !bar_) break;
      const LRESULT result = DefWindowProcW(hwnd, message, wparam, lparam);
      PaintBarLine();
      return result;
    }
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
