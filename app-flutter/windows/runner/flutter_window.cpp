#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <optional>
#include <shellapi.h>
#include <string>
#include <type_traits>
#include <vector>

#include <SystemMediaTransportControlsInterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kRiftShellNotifyMessage = WM_APP + 1;
constexpr UINT kRiftMediaPlaybackActionMessage = WM_APP + 2;
constexpr UINT kRiftShellNotifyId = 9001;
constexpr UINT_PTR kWindowsMediaPlaybackTimerId = 9002;
constexpr UINT kWindowsMediaPlaybackPollMs = 1000;

winrt::Windows::Media::SystemMediaTransportControls g_remote_media_controls{nullptr};
winrt::event_token g_remote_media_button_pressed_token{};
bool g_remote_media_button_handler_registered = false;

std::wstring Utf16FromUtf8(const std::string& utf8_string);
std::string Utf8FromWide(const std::wstring& value);
std::string Utf8FromHString(const winrt::hstring& value);
std::string Rfc3339NowUtc();

template <typename TAsync>
auto AwaitAsync(const TAsync& async_operation) {
  HANDLE completed_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (completed_event == nullptr) {
    throw std::runtime_error("Failed to create Windows event.");
  }

  async_operation.Completed(
      [completed_event](auto&&, auto&&) noexcept { SetEvent(completed_event); });

  while (true) {
    DWORD wait_result = MsgWaitForMultipleObjects(
        1, &completed_event, FALSE, INFINITE, QS_ALLINPUT);
    if (wait_result == WAIT_OBJECT_0) {
      break;
    }
    if (wait_result == WAIT_OBJECT_0 + 1) {
      MSG msg;
      while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
      }
    }
  }

  CloseHandle(completed_event);

  if constexpr (std::is_same_v<decltype(async_operation.GetResults()), void>) {
    async_operation.GetResults();
  } else {
    return async_operation.GetResults();
  }
}

void LogClipboardMessage(const std::string& message) {
  std::wstring wide_message = Utf16FromUtf8(message);
  if (!wide_message.empty()) {
    OutputDebugStringW((L"Rift clipboard bridge: " + wide_message + L"\n").c_str());
  }
}

void LogMediaPlaybackMessage(const std::string& message) {
  std::wstring wide_message = Utf16FromUtf8(message);
  if (!wide_message.empty()) {
    OutputDebugStringW(
        (L"Rift media playback bridge: " + wide_message + L"\n").c_str());
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

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }

  int target_length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (target_length <= 0) {
    return std::string();
  }

  std::string utf8;
  utf8.resize(target_length);
  int converted_length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), utf8.data(), target_length, nullptr,
      nullptr);
  if (converted_length <= 0) {
    return std::string();
  }

  return utf8;
}

std::string Utf8FromHString(const winrt::hstring& value) {
  return Utf8FromWide(std::wstring(value.c_str()));
}

std::string Rfc3339NowUtc() {
  SYSTEMTIME system_time = {};
  GetSystemTime(&system_time);
  char buffer[32] = {};
  snprintf(buffer, sizeof(buffer), "%04d-%02d-%02dT%02d:%02d:%02dZ",
           system_time.wYear, system_time.wMonth, system_time.wDay,
           system_time.wHour, system_time.wMinute, system_time.wSecond);
  return std::string(buffer);
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
  RegisterWindowsMediaPlaybackEventChannel();
  RegisterWindowsMediaPlaybackMethodChannel();
  RegisterWindowsShellMethodChannel();
  InitializeWindowsMediaPlaybackObserver();
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
  StopWindowsMediaPlaybackObservation();
  windows_media_playback_event_sink_.reset();
  windows_media_playback_event_channel_.reset();
  windows_media_playback_method_channel_.reset();
  CleanupShellNotificationIcon();
  ClearMediaPlayback();
  windows_shell_method_channel_.reset();
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
    case kRiftMediaPlaybackActionMessage:
      DispatchPendingMediaPlaybackAction();
      return 0;
    case WM_TIMER:
      if (wparam == kWindowsMediaPlaybackTimerId) {
        PollWindowsMediaPlayback();
        return 0;
      }
      break;
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

void FlutterWindow::RegisterWindowsMediaPlaybackEventChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  windows_media_playback_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "rift/windows/media_playback_events",
          &flutter::StandardMethodCodec::GetInstance());

  auto handler =
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](
              const flutter::EncodableValue*,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events) -> std::unique_ptr<
              flutter::StreamHandlerError<flutter::EncodableValue>> {
            windows_media_playback_event_sink_ = std::move(events);
            return nullptr;
          },
          [this](
              const flutter::EncodableValue*) -> std::unique_ptr<
              flutter::StreamHandlerError<flutter::EncodableValue>> {
            windows_media_playback_event_sink_.reset();
            return nullptr;
          });

  windows_media_playback_event_channel_->SetStreamHandler(std::move(handler));
}

void FlutterWindow::RegisterWindowsMediaPlaybackMethodChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  windows_media_playback_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "rift/windows/media_playback",
          &flutter::StandardMethodCodec::GetInstance());

  windows_media_playback_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto method_name = call.method_name();
        if (method_name == "startObservation") {
          StartWindowsMediaPlaybackObservation();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method_name == "stopObservation") {
          StopWindowsMediaPlaybackObservation();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method_name == "performAction") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_args", "Expected map arguments.");
            return;
          }

          const auto action_it =
              arguments->find(flutter::EncodableValue("action"));
          if (action_it == arguments->end()) {
            result->Error("invalid_args", "action is required.");
            return;
          }

          const auto* action = std::get_if<std::string>(&action_it->second);
          if (action == nullptr || action->empty()) {
            result->Error("invalid_args", "action must be a string.");
            return;
          }

          std::optional<int64_t> position_ms;
          const auto position_it =
              arguments->find(flutter::EncodableValue("positionMs"));
          if (position_it != arguments->end()) {
            if (const auto* int32_value =
                    std::get_if<int32_t>(&position_it->second)) {
              position_ms = *int32_value;
            } else if (const auto* int64_value =
                           std::get_if<int64_t>(&position_it->second)) {
              position_ms = *int64_value;
            }
          }

          auto action_result =
              PerformWindowsMediaPlaybackAction(*action, position_ms);
          if (!action_result.has_value()) {
            result->Error("media_unavailable",
                          "The Windows media playback bridge is unavailable.");
            return;
          }

          result->Success(flutter::EncodableValue(*action_result));
          return;
        }

        result->NotImplemented();
      });
}

void FlutterWindow::InitializeWindowsMediaPlaybackObserver() {}

void FlutterWindow::StartWindowsMediaPlaybackObservation() {
  windows_media_playback_observing_ = true;
  if (GetHandle() != nullptr && windows_media_playback_timer_id_ == 0) {
    windows_media_playback_timer_id_ =
        SetTimer(GetHandle(), kWindowsMediaPlaybackTimerId,
                 kWindowsMediaPlaybackPollMs, nullptr);
  }
  PollWindowsMediaPlayback();
}

void FlutterWindow::StopWindowsMediaPlaybackObservation() {
  windows_media_playback_observing_ = false;
  if (GetHandle() != nullptr && windows_media_playback_timer_id_ != 0) {
    KillTimer(GetHandle(), windows_media_playback_timer_id_);
    windows_media_playback_timer_id_ = 0;
  }
}

flutter::EncodableMap FlutterWindow::SnapshotWindowsMediaPlayback() {
  flutter::EncodableMap snapshot;

  using namespace winrt::Windows::Media::Control;
  auto manager = AwaitAsync(
      GlobalSystemMediaTransportControlsSessionManager::RequestAsync());
  auto session = manager.GetCurrentSession();
  if (session == nullptr) {
    return snapshot;
  }

  auto playback_info = session.GetPlaybackInfo();
  auto controls = playback_info.Controls();
  auto timeline = session.GetTimelineProperties();
  auto properties = AwaitAsync(session.TryGetMediaPropertiesAsync());

  const auto playback_id = GetWindowsPlaybackId();
  snapshot[flutter::EncodableValue("playbackId")] =
      flutter::EncodableValue(playback_id);
  snapshot[flutter::EncodableValue("sourcePlatform")] =
      flutter::EncodableValue("windows");

  auto app_id = Utf8FromHString(session.SourceAppUserModelId());
  if (app_id == "app_flutter.exe") {
    return flutter::EncodableMap();
  }
  snapshot[flutter::EncodableValue("appId")] =
      flutter::EncodableValue(app_id);
  snapshot[flutter::EncodableValue("appName")] =
      flutter::EncodableValue(app_id.empty() ? "Windows media" : app_id);

  auto title = Utf8FromHString(properties.Title());
  auto artist = Utf8FromHString(properties.Artist());
  auto album = Utf8FromHString(properties.AlbumTitle());
  if (!title.empty()) {
    snapshot[flutter::EncodableValue("title")] = flutter::EncodableValue(title);
  }
  if (!artist.empty()) {
    snapshot[flutter::EncodableValue("artist")] = flutter::EncodableValue(artist);
  }
  if (!album.empty()) {
    snapshot[flutter::EncodableValue("album")] = flutter::EncodableValue(album);
  }

  std::string playback_state = "stopped";
  switch (playback_info.PlaybackStatus()) {
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing:
      playback_state = "playing";
      break;
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused:
      playback_state = "paused";
      break;
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Changing:
      playback_state = "buffering";
      break;
    default:
      playback_state = "stopped";
      break;
  }
  snapshot[flutter::EncodableValue("playbackState")] =
      flutter::EncodableValue(playback_state);

  auto position_ms = timeline.Position().count() / 10000;
  auto duration_ms = timeline.EndTime().count() / 10000;
  if (position_ms < 0) {
    position_ms = 0;
  }
  if (duration_ms < 0) {
    duration_ms = 0;
  }
  snapshot[flutter::EncodableValue("positionMs")] = flutter::EncodableValue(
      static_cast<int64_t>(position_ms));
  snapshot[flutter::EncodableValue("durationMs")] = flutter::EncodableValue(
      static_cast<int64_t>(duration_ms));

  snapshot[flutter::EncodableValue("canPlay")] =
      flutter::EncodableValue(controls.IsPlayEnabled());
  snapshot[flutter::EncodableValue("canPause")] =
      flutter::EncodableValue(controls.IsPauseEnabled());
  snapshot[flutter::EncodableValue("canSkipNext")] =
      flutter::EncodableValue(controls.IsNextEnabled());
  snapshot[flutter::EncodableValue("canSkipPrevious")] =
      flutter::EncodableValue(controls.IsPreviousEnabled());
  snapshot[flutter::EncodableValue("canSeek")] =
      flutter::EncodableValue(controls.IsPlaybackPositionEnabled());
  snapshot[flutter::EncodableValue("updatedAt")] =
      flutter::EncodableValue(Rfc3339NowUtc());

  return snapshot;
}

flutter::EncodableMap FlutterWindow::BuildWindowsMediaPlaybackEvent(
    const std::string& event_type,
    const flutter::EncodableMap& snapshot) const {
  flutter::EncodableMap event(snapshot);
  event[flutter::EncodableValue("eventType")] =
      flutter::EncodableValue(event_type);
  return event;
}

flutter::EncodableMap FlutterWindow::BuildWindowsMediaPlaybackRemovedEvent()
    const {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("eventType")] =
      flutter::EncodableValue("removed");
  event[flutter::EncodableValue("playbackId")] =
      flutter::EncodableValue(current_windows_playback_id_);
  event[flutter::EncodableValue("sourcePlatform")] =
      flutter::EncodableValue("windows");
  event[flutter::EncodableValue("removedAt")] =
      flutter::EncodableValue(Rfc3339NowUtc());
  return event;
}

void FlutterWindow::PollWindowsMediaPlayback() {
  if (!windows_media_playback_observing_ ||
      windows_media_playback_event_sink_ == nullptr) {
    return;
  }

  try {
    auto snapshot = SnapshotWindowsMediaPlayback();
    const auto playback_it =
        snapshot.find(flutter::EncodableValue("playbackId"));
    const bool has_playback = playback_it != snapshot.end();

    if (!has_playback) {
      if (!current_windows_playback_id_.empty()) {
        windows_media_playback_event_sink_->Success(
            flutter::EncodableValue(BuildWindowsMediaPlaybackRemovedEvent()));
        current_windows_playback_id_.clear();
        last_windows_media_playback_snapshot_.reset();
      }
      return;
    }

    const auto playback_id = std::get<std::string>(playback_it->second);
    if (!current_windows_playback_id_.empty() &&
        current_windows_playback_id_ != playback_id) {
      windows_media_playback_event_sink_->Success(
          flutter::EncodableValue(BuildWindowsMediaPlaybackRemovedEvent()));
      last_windows_media_playback_snapshot_.reset();
    }

    current_windows_playback_id_ = playback_id;
    const bool is_posted = !last_windows_media_playback_snapshot_.has_value();
    if (!last_windows_media_playback_snapshot_.has_value() ||
        last_windows_media_playback_snapshot_.value() != snapshot) {
      last_windows_media_playback_snapshot_ = snapshot;
      windows_media_playback_event_sink_->Success(flutter::EncodableValue(
          BuildWindowsMediaPlaybackEvent(is_posted ? "posted" : "updated",
                                         snapshot)));
    }
  } catch (...) {
  }
}

std::optional<flutter::EncodableMap>
FlutterWindow::PerformWindowsMediaPlaybackAction(
    const std::string& action,
    std::optional<int64_t> position_ms) {
  using namespace winrt::Windows::Media::Control;

  flutter::EncodableMap response;
  response[flutter::EncodableValue("success")] = flutter::EncodableValue(false);

  try {
    auto manager = AwaitAsync(
        GlobalSystemMediaTransportControlsSessionManager::RequestAsync());
    auto session = manager.GetCurrentSession();
    if (session == nullptr) {
      response[flutter::EncodableValue("failureReason")] =
          flutter::EncodableValue("CapabilityUnavailable");
      response[flutter::EncodableValue("message")] =
          flutter::EncodableValue("No active Windows media session is available.");
      return response;
    }

    bool success = false;
    if (action == "play") {
      success = AwaitAsync(session.TryPlayAsync());
    } else if (action == "pause") {
      success = AwaitAsync(session.TryPauseAsync());
    } else if (action == "togglePlayPause") {
      success = AwaitAsync(session.TryTogglePlayPauseAsync());
    } else if (action == "next") {
      success = AwaitAsync(session.TrySkipNextAsync());
    } else if (action == "previous") {
      success = AwaitAsync(session.TrySkipPreviousAsync());
    } else if (action == "seek") {
      success = position_ms.has_value()
                    ? AwaitAsync(
                          session.TryChangePlaybackPositionAsync(*position_ms))
                    : false;
    } else {
      response[flutter::EncodableValue("failureReason")] =
          flutter::EncodableValue("CapabilityUnavailable");
      response[flutter::EncodableValue("message")] =
          flutter::EncodableValue("Unsupported media playback action.");
      return response;
    }

    response[flutter::EncodableValue("success")] =
        flutter::EncodableValue(success);
    if (!success) {
      response[flutter::EncodableValue("failureReason")] =
          flutter::EncodableValue("PeerRejected");
      response[flutter::EncodableValue("message")] =
          flutter::EncodableValue("The Windows media session rejected the action.");
    }
    return response;
  } catch (...) {
    response[flutter::EncodableValue("failureReason")] =
        flutter::EncodableValue("CapabilityUnavailable");
    response[flutter::EncodableValue("message")] =
        flutter::EncodableValue("The Windows media playback bridge is unavailable.");
    return response;
  }
}

std::string FlutterWindow::GetWindowsPlaybackId() const {
  return "windows-current-session";
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
        if (method_name == "clearMediaPlayback") {
          result->Success(flutter::EncodableValue(ClearMediaPlayback()));
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr && method_name != "clearMediaPlayback") {
          result->Error("invalid_args", "Expected map arguments.");
          return;
        }

        if (method_name == "showMediaPlayback") {
          const auto playback_it =
              arguments->find(flutter::EncodableValue("playback"));
          if (playback_it == arguments->end()) {
            result->Error("invalid_args", "playback is required.");
            return;
          }

          const auto* playback =
              std::get_if<flutter::EncodableMap>(&playback_it->second);
          if (playback == nullptr) {
            result->Error("invalid_args", "playback must be a map.");
            return;
          }

          result->Success(flutter::EncodableValue(ShowMediaPlayback(*playback)));
          return;
        }

        if (method_name != "showTransferNotification" &&
            method_name != "showNotification") {
          result->NotImplemented();
          return;
        }

        const auto title_it = arguments->find(flutter::EncodableValue("title"));
        const auto body_it = arguments->find(flutter::EncodableValue("body"));
        const auto destination_it =
            arguments->find(flutter::EncodableValue("destinationPath"));
        const auto route_it = arguments->find(flutter::EncodableValue("route"));
        if (title_it == arguments->end() || body_it == arguments->end()) {
          result->Error("invalid_args", "title and body are required.");
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
          result->Error("invalid_args", "title and body must be strings.");
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
            if (const auto* route_value =
                    std::get_if<std::string>(&route_it->second)) {
              route = *route_value;
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

bool FlutterWindow::ShowMediaPlayback(const flutter::EncodableMap& playback) {
  active_remote_media_playback_ = playback;
  const auto title_it = playback.find(flutter::EncodableValue("title"));
  if (title_it != playback.end()) {
    if (const auto* title = std::get_if<std::string>(&title_it->second)) {
      LogMediaPlaybackMessage("showMediaPlayback title=" + *title);
    }
  } else {
    LogMediaPlaybackMessage("showMediaPlayback");
  }
  UpdateRemoteMediaPlaybackControls(playback);
  return g_remote_media_controls != nullptr;
}

bool FlutterWindow::ClearMediaPlayback() {
  LogMediaPlaybackMessage("clearMediaPlayback");
  active_remote_media_playback_.clear();
  pending_media_playback_action_payload_.clear();

  if (g_remote_media_controls == nullptr) {
    return true;
  }

  if (g_remote_media_button_handler_registered) {
    g_remote_media_controls.ButtonPressed(g_remote_media_button_pressed_token);
    g_remote_media_button_handler_registered = false;
  }

  auto updater = g_remote_media_controls.DisplayUpdater();
  updater.ClearAll();
  updater.Update();
  g_remote_media_controls.IsPlayEnabled(false);
  g_remote_media_controls.IsPauseEnabled(false);
  g_remote_media_controls.IsNextEnabled(false);
  g_remote_media_controls.IsPreviousEnabled(false);
  g_remote_media_controls.IsStopEnabled(false);
  g_remote_media_controls.PlaybackStatus(
      winrt::Windows::Media::MediaPlaybackStatus::Closed);
  g_remote_media_controls.IsEnabled(false);
  g_remote_media_controls = nullptr;
  return true;
}

void FlutterWindow::UpdateRemoteMediaPlaybackControls(
    const flutter::EncodableMap& playback) {
  if (GetHandle() == nullptr) {
    LogMediaPlaybackMessage("UpdateRemoteMediaPlaybackControls aborted: no window handle");
    return;
  }

  if (g_remote_media_controls == nullptr) {
    LogMediaPlaybackMessage("creating remote SMTC");
    auto interop = winrt::get_activation_factory<
        winrt::Windows::Media::SystemMediaTransportControls,
        ISystemMediaTransportControlsInterop>();
    g_remote_media_controls = winrt::capture<
        winrt::Windows::Media::SystemMediaTransportControls>(
        interop, &ISystemMediaTransportControlsInterop::GetForWindow,
        GetHandle());
  }

  if (!g_remote_media_button_handler_registered) {
    g_remote_media_button_pressed_token = g_remote_media_controls.ButtonPressed(
        [this](auto&&, winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs const& args) {
          std::string action;
          switch (args.Button()) {
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Play:
              action = "play";
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Pause:
              action = "pause";
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Next:
              action = "next";
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Previous:
              action = "previous";
              break;
            default:
              return;
          }

          const auto source_it = active_remote_media_playback_.find(
              flutter::EncodableValue("sourceDeviceId"));
          const auto playback_it = active_remote_media_playback_.find(
              flutter::EncodableValue("playbackId"));
          if (source_it == active_remote_media_playback_.end() ||
              playback_it == active_remote_media_playback_.end()) {
            return;
          }

          const auto* source_device_id =
              std::get_if<std::string>(&source_it->second);
          const auto* playback_id = std::get_if<std::string>(&playback_it->second);
          if (source_device_id == nullptr || playback_id == nullptr ||
              source_device_id->empty() || playback_id->empty()) {
            return;
          }

          pending_media_playback_action_payload_.clear();
          pending_media_playback_action_payload_[
              flutter::EncodableValue("sourceDeviceId")] =
              flutter::EncodableValue(*source_device_id);
          pending_media_playback_action_payload_[flutter::EncodableValue("playbackId")] =
              flutter::EncodableValue(*playback_id);
          pending_media_playback_action_payload_[flutter::EncodableValue("action")] =
              flutter::EncodableValue(action);
          LogMediaPlaybackMessage("dispatch mediaPlaybackAction action=" + action);
          PostMessage(GetHandle(), kRiftMediaPlaybackActionMessage, 0, 0);
        });
    g_remote_media_button_handler_registered = true;
  }

  auto find_string = [&playback](const char* key) -> std::string {
    const auto it = playback.find(flutter::EncodableValue(key));
    if (it == playback.end()) {
      return std::string();
    }
    if (const auto* value = std::get_if<std::string>(&it->second)) {
      return *value;
    }
    return std::string();
  };
  auto find_bool = [&playback](const char* key) -> bool {
    const auto it = playback.find(flutter::EncodableValue(key));
    return it != playback.end() && std::get_if<bool>(&it->second) != nullptr &&
           *std::get_if<bool>(&it->second);
  };

  const auto title = find_string("title");
  const auto artist = find_string("artist");
  const auto album = find_string("album");
  const auto app_name = find_string("appName");
  const auto playback_state = find_string("playbackState");

  LogMediaPlaybackMessage("updating remote SMTC state");
  g_remote_media_controls.IsEnabled(true);
  g_remote_media_controls.IsPlayEnabled(find_bool("canPlay"));
  g_remote_media_controls.IsPauseEnabled(find_bool("canPause"));
  g_remote_media_controls.IsNextEnabled(find_bool("canSkipNext"));
  g_remote_media_controls.IsPreviousEnabled(find_bool("canSkipPrevious"));
  g_remote_media_controls.IsStopEnabled(false);

  if (playback_state == "playing") {
    g_remote_media_controls.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Playing);
  } else if (playback_state == "paused") {
    g_remote_media_controls.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Paused);
  } else if (playback_state == "buffering") {
    g_remote_media_controls.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Changing);
  } else {
    g_remote_media_controls.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Stopped);
  }

  auto updater = g_remote_media_controls.DisplayUpdater();
  updater.ClearAll();
  updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
  auto music = updater.MusicProperties();
  music.Title(winrt::to_hstring(title.empty() ? app_name : title));
  music.Artist(winrt::to_hstring(artist));
  music.AlbumTitle(winrt::to_hstring(album));

  const auto artwork_it = playback.find(flutter::EncodableValue("artwork"));
  if (artwork_it != playback.end()) {
    if (const auto* artwork =
            std::get_if<flutter::EncodableMap>(&artwork_it->second)) {
      const auto data_it = artwork->find(flutter::EncodableValue("dataBase64"));
      if (data_it != artwork->end()) {
        if (const auto* data_base64 =
                std::get_if<std::string>(&data_it->second)) {
          try {
            using namespace winrt::Windows::Security::Cryptography;
            using namespace winrt::Windows::Storage::Streams;
            auto buffer =
                CryptographicBuffer::DecodeFromBase64String(winrt::to_hstring(*data_base64));
            InMemoryRandomAccessStream stream;
            DataWriter writer(stream);
            writer.WriteBuffer(buffer);
            AwaitAsync(writer.StoreAsync());
            AwaitAsync(writer.FlushAsync());
            writer.DetachStream();
            stream.Seek(0);
            updater.Thumbnail(RandomAccessStreamReference::CreateFromStream(stream));
            LogMediaPlaybackMessage("applied remote artwork");
          } catch (...) {
            LogMediaPlaybackMessage("failed to decode remote artwork");
          }
        }
      }
    }
  }

  updater.Update();
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

void FlutterWindow::DispatchPendingMediaPlaybackAction() {
  if (!windows_shell_method_channel_ ||
      pending_media_playback_action_payload_.empty()) {
    LogMediaPlaybackMessage("DispatchPendingMediaPlaybackAction skipped");
    return;
  }

  LogMediaPlaybackMessage("InvokeMethod mediaPlaybackAction");
  windows_shell_method_channel_->InvokeMethod(
      "mediaPlaybackAction",
      std::make_unique<flutter::EncodableValue>(
          pending_media_playback_action_payload_));
}
