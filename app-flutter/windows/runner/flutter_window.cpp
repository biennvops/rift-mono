#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kRiftShellNotifyMessage = WM_APP + 1;
constexpr UINT kRiftShellNotifyId = 9001;
// WM_COPYDATA identifier for file handoff from a second app instance.
constexpr ULONG_PTR kRiftSendFilesCopyDataId = 0x52465446;  // 'RFTF'

std::wstring Utf16FromUtf8(const std::string& utf8_string);

void LogClipboardMessage(const std::string& message) {
  std::wstring wide_message = Utf16FromUtf8(message);
  if (!wide_message.empty()) {
    OutputDebugStringW((L"Rift clipboard bridge: " + wide_message + L"\n").c_str());
  }
}

std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }

  int target_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
      static_cast<int>(utf8_string.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }

  std::wstring utf16_string;
  utf16_string.resize(target_length);
  int converted_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
      static_cast<int>(utf8_string.size()), utf16_string.data(),
      target_length);
  if (converted_length <= 0) {
    return std::wstring();
  }

  return utf16_string;
}

bool ReadGlobalMemory(HANDLE handle, std::vector<uint8_t>* bytes) {
  if (handle == nullptr || bytes == nullptr) {
    return false;
  }

  auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
  if (data == nullptr) {
    return false;
  }

  SIZE_T size = GlobalSize(handle);
  bytes->assign(data, data + size);
  GlobalUnlock(handle);
  return true;
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
  RegisterClipboardEventChannel();
  RegisterClipboardMethodChannel();
  RegisterWindowsShellMethodChannel();
  RegisterSendFilesMethodChannel();
  InitializeShellNotificationIcon();
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
  if (clipboard_listener_registered_ && GetHandle() != nullptr) {
    RemoveClipboardFormatListener(GetHandle());
    clipboard_listener_registered_ = false;
  }
  clipboard_event_sink_.reset();
  clipboard_event_channel_.reset();
  clipboard_method_channel_.reset();
  CleanupShellNotificationIcon();
  windows_shell_method_channel_.reset();
  send_files_method_channel_.reset();
  send_files_channel_ready_ = false;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_CLIPBOARDUPDATE:
      if (clipboard_event_sink_) {
        clipboard_event_sink_->Success(flutter::EncodableValue(true));
      }
      return 0;
    case kRiftShellNotifyMessage:
      if (lparam == NIN_BALLOONUSERCLICK) {
        DispatchPendingNotificationAction();
        return 0;
      }
      break;
    case WM_COPYDATA: {
      const auto* copy_data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (copy_data != nullptr &&
          copy_data->dwData == kRiftSendFilesCopyDataId &&
          copy_data->lpData != nullptr &&
          copy_data->cbData >= sizeof(wchar_t) &&
          copy_data->cbData % sizeof(wchar_t) == 0) {
        // Payload: double-null-terminated UTF-16 path list.
        const auto* data = static_cast<const wchar_t*>(copy_data->lpData);
        const size_t length = copy_data->cbData / sizeof(wchar_t);
        std::vector<std::wstring> paths;
        size_t start = 0;
        while (start < length && data[start] != L'\0') {
          size_t end = start;
          while (end < length && data[end] != L'\0') {
            ++end;
          }
          if (end == length) {
            break;
          }
          paths.emplace_back(data + start, end - start);
          start = end + 1;
        }
        QueueSendFiles(paths);
        // Bring the existing window to the foreground for the user.
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
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

void FlutterWindow::RegisterClipboardEventChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  clipboard_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "rift/desktop/clipboard_events",
          &flutter::StandardMethodCodec::GetInstance());

  auto handler =
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](
              const flutter::EncodableValue*,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events) -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            clipboard_event_sink_ = std::move(events);
            if (!clipboard_listener_registered_ && GetHandle() != nullptr) {
              clipboard_listener_registered_ =
                  AddClipboardFormatListener(GetHandle()) == TRUE;
            }
            return nullptr;
          },
          [this](
              const flutter::EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            clipboard_event_sink_.reset();
            return nullptr;
          });

  clipboard_event_channel_->SetStreamHandler(std::move(handler));
}

void FlutterWindow::RegisterClipboardMethodChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  clipboard_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "rift/desktop/clipboard",
          &flutter::StandardMethodCodec::GetInstance());

  clipboard_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto method_name = call.method_name();
        if (method_name == "getClipboardContent") {
          LogClipboardMessage("method getClipboardContent");
          if (!OpenClipboard(GetHandle())) {
            LogClipboardMessage("OpenClipboard failed for read.");
            result->Success();
            return;
          }

          UINT png_format = RegisterClipboardFormatW(L"PNG");
          if (IsClipboardFormatAvailable(png_format)) {
            HANDLE handle = GetClipboardData(png_format);
            std::vector<uint8_t> bytes;
            if (ReadGlobalMemory(handle, &bytes)) {
              CloseClipboard();
              LogClipboardMessage("read image/png payload (" +
                                  std::to_string(bytes.size()) + " bytes).");
              flutter::EncodableMap payload;
              payload[flutter::EncodableValue("contentType")] =
                  flutter::EncodableValue("image/png");
              payload[flutter::EncodableValue("bytes")] =
                  flutter::EncodableValue(bytes);
              result->Success(flutter::EncodableValue(payload));
              return;
            }
          }

          if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
            HANDLE handle = GetClipboardData(CF_UNICODETEXT);
            auto* data = static_cast<const wchar_t*>(GlobalLock(handle));
            if (data != nullptr) {
              std::string text = Utf8FromUtf16(data);
              GlobalUnlock(handle);
              CloseClipboard();
              LogClipboardMessage("read text/plain payload (" +
                                  std::to_string(text.size()) + " bytes).");
              flutter::EncodableMap payload;
              payload[flutter::EncodableValue("contentType")] =
                  flutter::EncodableValue("text/plain");
              payload[flutter::EncodableValue("bytes")] =
                  flutter::EncodableValue(std::vector<uint8_t>(
                      text.begin(), text.end()));
              result->Success(flutter::EncodableValue(payload));
              return;
            }
          }

          CloseClipboard();
          LogClipboardMessage("no supported clipboard payload available.");
          result->Success();
          return;
        }

        if (method_name == "setClipboardContent") {
          LogClipboardMessage("method setClipboardContent");
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_args", "Expected map arguments.");
            return;
          }

          const auto content_type_it =
              arguments->find(flutter::EncodableValue("contentType"));
          const auto bytes_it =
              arguments->find(flutter::EncodableValue("bytes"));
          if (content_type_it == arguments->end() ||
              bytes_it == arguments->end()) {
            result->Error("invalid_args",
                          "contentType and bytes are required.");
            return;
          }

          const auto* content_type =
              std::get_if<std::string>(&content_type_it->second);
          const auto* bytes =
              std::get_if<std::vector<uint8_t>>(&bytes_it->second);
          if (content_type == nullptr || bytes == nullptr) {
            result->Error("invalid_args",
                          "contentType must be string and bytes must be Uint8List.");
            return;
          }

          bool applied = false;
          UINT clipboard_format = 0;
          HGLOBAL memory = nullptr;
          if (*content_type == "text/plain" || *content_type == "clipboard") {
            std::string utf8_text(bytes->begin(), bytes->end());
            std::wstring utf16_text = Utf16FromUtf8(utf8_text);
            if (utf16_text.empty() && !bytes->empty()) {
              LogClipboardMessage("failed to decode text/plain payload.");
            } else {
              clipboard_format = CF_UNICODETEXT;
              memory = GlobalAlloc(
                GMEM_MOVEABLE,
                (utf16_text.size() + 1) * sizeof(wchar_t));
              if (memory != nullptr) {
                auto* target = static_cast<wchar_t*>(GlobalLock(memory));
                if (target != nullptr) {
                  memcpy(target, utf16_text.c_str(),
                         utf16_text.size() * sizeof(wchar_t));
                  target[utf16_text.size()] = L'\0';
                  GlobalUnlock(memory);
                } else {
                  GlobalFree(memory);
                  memory = nullptr;
                }
              }
            }
          } else if (*content_type == "image/png") {
            clipboard_format = RegisterClipboardFormatW(L"PNG");
            memory = GlobalAlloc(GMEM_MOVEABLE, bytes->size());
            if (memory != nullptr) {
              auto* target = static_cast<uint8_t*>(GlobalLock(memory));
              if (target != nullptr) {
                memcpy(target, bytes->data(), bytes->size());
                GlobalUnlock(memory);
              } else {
                GlobalFree(memory);
                memory = nullptr;
              }
            }
          }
          if (*content_type != "text/plain" && *content_type != "clipboard" &&
              *content_type != "image/png") {
            LogClipboardMessage("unsupported write content type " + *content_type);
          }

          if (memory == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }

          if (!OpenClipboard(GetHandle())) {
            LogClipboardMessage("OpenClipboard failed for write.");
            GlobalFree(memory);
            result->Success(flutter::EncodableValue(false));
            return;
          }

          if (!EmptyClipboard()) {
            LogClipboardMessage("EmptyClipboard failed for write.");
            GlobalFree(memory);
            CloseClipboard();
            result->Success(flutter::EncodableValue(false));
            return;
          }

          applied = SetClipboardData(clipboard_format, memory) != nullptr;
          if (*content_type == "text/plain" || *content_type == "clipboard") {
            LogClipboardMessage(std::string("write text/plain payload (") +
                                std::to_string(bytes->size()) +
                                " bytes) success=" +
                                (applied ? "true" : "false"));
          } else if (*content_type == "image/png") {
            LogClipboardMessage(std::string("write image/png payload (") +
                                std::to_string(bytes->size()) +
                                " bytes) success=" +
                                (applied ? "true" : "false"));
          }
          if (!applied) {
            GlobalFree(memory);
          }

          CloseClipboard();
          result->Success(flutter::EncodableValue(applied));
          return;
        }

        result->NotImplemented();
      });
}

void FlutterWindow::RegisterWindowsShellMethodChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  windows_shell_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "rift/windows/shell",
          &flutter::StandardMethodCodec::GetInstance());

  windows_shell_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto method_name = call.method_name();
        if (method_name != "showTransferNotification" &&
            method_name != "showNotification") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_args", "Expected map arguments.");
          return;
        }

        const auto title_it = arguments->find(flutter::EncodableValue("title"));
        const auto body_it = arguments->find(flutter::EncodableValue("body"));
        const auto destination_it =
            arguments->find(flutter::EncodableValue("destinationPath"));
        const auto route_it = arguments->find(flutter::EncodableValue("route"));
        if (title_it == arguments->end() || body_it == arguments->end()) {
          result->Error(
              "invalid_args",
              "title and body are required.");
          return;
        }

        const auto* title = std::get_if<std::string>(&title_it->second);
        const auto* body = std::get_if<std::string>(&body_it->second);
        std::string destination;
        if (destination_it != arguments->end()) {
          if (const auto* value =
                  std::get_if<std::string>(&destination_it->second)) {
            destination = *value;
          }
        }
        if (title == nullptr || body == nullptr) {
          result->Error(
              "invalid_args",
              "title and body must be strings.");
          return;
        }

        bool shown = false;
        if (method_name == "showTransferNotification") {
          shown = ShowTransferNotification(Utf16FromUtf8(*title),
                                          Utf16FromUtf8(*body),
                                          Utf16FromUtf8(destination));
        } else {
          std::string route;
          flutter::EncodableMap payload;

          if (route_it != arguments->end()) {
            if (const auto* value = std::get_if<std::string>(&route_it->second)) {
              route = *value;
            }
          }
          const auto payload_it =
              arguments->find(flutter::EncodableValue("payload"));
          if (payload_it != arguments->end()) {
            if (const auto* payload_map =
                    std::get_if<flutter::EncodableMap>(&payload_it->second)) {
              payload = *payload_map;
            }
          }
          shown = ShowNotification(Utf16FromUtf8(*title), Utf16FromUtf8(*body),
                                   route, payload,
                                   Utf16FromUtf8(destination));
        }
        result->Success(flutter::EncodableValue(shown));
      });
}

void FlutterWindow::QueueSendFiles(const std::vector<std::wstring>& paths) {
  for (const auto& path : paths) {
    // Only hand off readable regular files, mirroring the Linux runner.
    DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      continue;
    }

    std::wstring file_name = path;
    const size_t separator = file_name.find_last_of(L"\\/");
    if (separator != std::wstring::npos) {
      file_name = file_name.substr(separator + 1);
    }
    if (file_name.empty()) {
      continue;
    }

    flutter::EncodableMap item;
    item[flutter::EncodableValue("localPath")] =
        flutter::EncodableValue(Utf8FromUtf16(path.c_str()));
    item[flutter::EncodableValue("fileName")] =
        flutter::EncodableValue(Utf8FromUtf16(file_name.c_str()));
    pending_send_files_.push_back(flutter::EncodableValue(item));
  }

  DispatchQueuedSendFiles();
}

void FlutterWindow::RegisterSendFilesMethodChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  send_files_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "rift/windows/send_files",
          &flutter::StandardMethodCodec::GetInstance());

  send_files_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "consumePendingItems") {
          send_files_channel_ready_ = true;
          flutter::EncodableList pending = std::move(pending_send_files_);
          pending_send_files_.clear();
          result->Success(flutter::EncodableValue(pending));
          return;
        }

        result->NotImplemented();
      });
}

void FlutterWindow::DispatchQueuedSendFiles() {
  if (!send_files_channel_ready_ || send_files_method_channel_ == nullptr ||
      pending_send_files_.empty()) {
    return;
  }

  flutter::EncodableList items = std::move(pending_send_files_);
  pending_send_files_.clear();
  send_files_method_channel_->InvokeMethod(
      "sendFilesSelected",
      std::make_unique<flutter::EncodableValue>(items));
}

void FlutterWindow::InitializeShellNotificationIcon() {
  if (shell_notification_icon_registered_ || GetHandle() == nullptr) {
    return;
  }

  NOTIFYICONDATAW icon_data = {};
  icon_data.cbSize = sizeof(icon_data);
  icon_data.hWnd = GetHandle();
  icon_data.uID = kRiftShellNotifyId;
  icon_data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon_data.uCallbackMessage = kRiftShellNotifyMessage;
  icon_data.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 0,
      0, LR_DEFAULTSIZE));
  wcscpy_s(icon_data.szTip, L"Rift");

  shell_notification_icon_registered_ =
      Shell_NotifyIconW(NIM_ADD, &icon_data) == TRUE;
  if (shell_notification_icon_registered_) {
    icon_data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon_data);
  }
  if (icon_data.hIcon != nullptr) {
    DestroyIcon(icon_data.hIcon);
  }
}

void FlutterWindow::CleanupShellNotificationIcon() {
  if (!shell_notification_icon_registered_ || GetHandle() == nullptr) {
    return;
  }

  NOTIFYICONDATAW icon_data = {};
  icon_data.cbSize = sizeof(icon_data);
  icon_data.hWnd = GetHandle();
  icon_data.uID = kRiftShellNotifyId;
  Shell_NotifyIconW(NIM_DELETE, &icon_data);
  shell_notification_icon_registered_ = false;
}

bool FlutterWindow::ShowTransferNotification(
    const std::wstring& title,
    const std::wstring& body,
    const std::wstring& destination_path) {
  return ShowNotification(title, body, "history.transfer_activity",
                          flutter::EncodableMap(), destination_path);
}

bool FlutterWindow::ShowNotification(
    const std::wstring& title,
    const std::wstring& body,
    const std::string& route,
    const flutter::EncodableMap& payload,
    const std::wstring& destination_path) {
  if (GetHandle() == nullptr) {
    return false;
  }
  InitializeShellNotificationIcon();
  if (!shell_notification_icon_registered_) {
    return false;
  }

  pending_notification_route_ = route;
  pending_notification_payload_ = payload;
  pending_notification_destination_path_ = destination_path;

  NOTIFYICONDATAW icon_data = {};
  icon_data.cbSize = sizeof(icon_data);
  icon_data.hWnd = GetHandle();
  icon_data.uID = kRiftShellNotifyId;
  icon_data.uFlags = NIF_INFO;
  icon_data.dwInfoFlags = NIIF_USER | NIIF_NOSOUND;
  wcsncpy_s(icon_data.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(icon_data.szInfo, body.c_str(), _TRUNCATE);
  return Shell_NotifyIconW(NIM_MODIFY, &icon_data) == TRUE;
}

void FlutterWindow::DispatchPendingNotificationAction() {
  if (GetHandle() != nullptr) {
    ShowWindow(GetHandle(), SW_RESTORE);
    SetForegroundWindow(GetHandle());
  }
  if (!windows_shell_method_channel_) {
    return;
  }

  flutter::EncodableMap payload = {
      {flutter::EncodableValue("route"),
       flutter::EncodableValue(pending_notification_route_)}};
  for (const auto& entry : pending_notification_payload_) {
    if (const auto* key = std::get_if<std::string>(&entry.first)) {
      payload[flutter::EncodableValue(*key)] = entry.second;
    }
  }
  if (!pending_notification_destination_path_.empty()) {
    payload[flutter::EncodableValue("destinationPath")] =
        flutter::EncodableValue(
            Utf8FromUtf16(pending_notification_destination_path_.c_str()));
  }

  windows_shell_method_channel_->InvokeMethod(
      "notificationActivated",
      std::make_unique<flutter::EncodableValue>(payload));
}
