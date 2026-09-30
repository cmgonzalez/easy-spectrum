#ifndef RUNNER_NATIVE_MENU_H_
#define RUNNER_NATIVE_MENU_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

// Barra de menús nativa de Windows (HMENU) descrita desde Dart por el canal
// cl.easysoft.easyspectrum/menu (ver lib/features/desktop/native_menu.dart).
//   Dart → C++: setMenu(lista de menús), setVisible(bool)
//   C++ → Dart: select(id), menuLoop(bool)
// Se dibuja a mano (owner-draw) con los colores del Spectrum: fondo negro, texto blanco,
// opción marcada en cian (como el menú del 128K) y las franjas del arcoíris a la derecha.
class NativeMenu {
 public:
  NativeMenu(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~NativeMenu();

  // Mensajes de la ventana principal que son del menú; nullopt si no lo son.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  // Lo que hace falta para medir y dibujar cada opción (dwItemData apunta aquí).
  struct Item {
    std::wstring text;      // con "&" de la letra de Alt
    std::wstring shortcut;  // lo que va después de "	"
    bool bar = false, radio = false, submenu = false, separator = false, rainbow = false;
  };
  using Items = std::vector<std::unique_ptr<Item>>;

  HMENU Build(const flutter::EncodableList& items, bool bar, Items& store);
  void Measure(MEASUREITEMSTRUCT* mis);
  void Draw(const DRAWITEMSTRUCT* dis);
  std::optional<LRESULT> MenuChar(wchar_t ch, HMENU menu);
  void PaintBarLine();
  HFONT Font(UINT dpi);
  void Apply(const flutter::EncodableList& menus);
  void Attach();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND hwnd_;
  HMENU bar_ = nullptr;
  bool visible_ = true;
  // Un cambio llegado con un menú abierto se aplica al cerrarlo (rehacer la barra
  // mientras el usuario la recorre la cerraría).
  bool in_menu_loop_ = false;
  std::optional<flutter::EncodableList> pending_;
  Items items_;
  HFONT font_ = nullptr;
  UINT font_dpi_ = 0;
};

#endif  // RUNNER_NATIVE_MENU_H_
