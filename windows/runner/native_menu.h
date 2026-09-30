#ifndef RUNNER_NATIVE_MENU_H_
#define RUNNER_NATIVE_MENU_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Barra de menús nativa de Windows (HMENU) descrita desde Dart por el canal
// cl.easysoft.easyspectrum/menu (ver lib/features/desktop/native_menu.dart).
//   Dart → C++: setMenu(lista de menús), setVisible(bool)
//   C++ → Dart: select(id), menuLoop(bool)
class NativeMenu {
 public:
  NativeMenu(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~NativeMenu();

  // Mensajes de la ventana principal que son del menú; nullopt si no lo son.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  HMENU Build(const flutter::EncodableList& items, bool bar);
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
};

#endif  // RUNNER_NATIVE_MENU_H_
