#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Abre Configuración › Aplicaciones predeterminadas en la página de Easy Spectrum
// (registrada por el instalador en RegisteredApplications, de usuario o de máquina).
// Sin instalar (zip), la página general.
void OpenDefaultAppsSettings() {
  const wchar_t* uri = L"ms-settings:defaultapps";
  auto registered = [](HKEY root) {
    return RegGetValueW(root, L"Software\\RegisteredApplications", L"EasySpectrum",
                        RRF_RT_REG_SZ, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
  };
  if (registered(HKEY_CURRENT_USER)) {
    uri = L"ms-settings:defaultapps?registeredAppUser=EasySpectrum";
  } else if (registered(HKEY_LOCAL_MACHINE)) {
    uri = L"ms-settings:defaultapps?registeredAppMachine=EasySpectrum";
  }
  ShellExecuteW(nullptr, L"open", uri, nullptr, nullptr, SW_SHOWNORMAL);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  menu_ = std::make_unique<NativeMenu>(
      flutter_controller_->engine()->messenger(), GetHandle());
  open_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "cl.easysoft.easyspectrum/open_args",
      &flutter::StandardMethodCodec::GetInstance());
  open_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "openDefaultApps") {
      OpenDefaultAppsSettings();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
  SetPropW(GetHandle(), kMainWindowProp, reinterpret_cast<HANDLE>(1));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemovePropW(GetHandle(), kMainWindowProp);
  menu_ = nullptr;
  open_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (menu_) {
    if (auto result = menu_->HandleMessage(hwnd, message, wparam, lparam)) {
      return *result;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      std::vector<std::string> args;
      if (open_channel_ &&
          DecodeOpenArgs(reinterpret_cast<const COPYDATASTRUCT*>(lparam), &args)) {
        flutter::EncodableList list;
        for (auto& a : args) list.emplace_back(a);
        open_channel_->InvokeMethod("open", std::make_unique<flutter::EncodableValue>(list));
        return TRUE;
      }
      break;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
