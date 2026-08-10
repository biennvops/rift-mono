#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Media.Playback.h>

#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Queues files opened with the app (Open With / file association) for
  // handoff into the Dart send queue once the channel is ready.
  void QueueSendFiles(const std::vector<std::wstring>& paths);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterClipboardEventChannel();
  void RegisterClipboardMethodChannel();
  void RegisterWindowsShellMethodChannel();
  void RegisterWindowsMediaPlaybackEventChannel();
  void RegisterWindowsMediaPlaybackMethodChannel();
  void RegisterSendFilesMethodChannel();
  void DispatchQueuedSendFiles();
  bool ShowWindowsMediaPlayback(const flutter::EncodableMap& playback);
  bool ClearWindowsMediaPlayback();
  bool StartWindowsMediaPlaybackObservation();
  bool StopWindowsMediaPlaybackObservation();
  void PollWindowsMediaPlaybackObservation();
  std::optional<flutter::EncodableMap> BuildObservedWindowsPlaybackSnapshot(
      winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession session,
      const std::string& updated_at);
  std::optional<flutter::EncodableMap> FindObservedWindowsPlayback(
      const std::string& playback_id,
      const std::string& updated_at);
  std::optional<flutter::EncodableMap> ReadObservedWindowsPlaybackState();
  flutter::EncodableMap BuildRemovedWindowsPlaybackEvent(
      const flutter::EncodableMap& previous,
      const std::string& removed_at);
  bool PerformObservedWindowsPlaybackAction(
      const std::string& playback_id,
      const std::string& action,
      std::optional<int64_t> position_ms,
      flutter::EncodableMap* response);
  void QueueWindowsMediaPlaybackAction(
      const std::string& action,
      std::optional<int64_t> position_ms = std::nullopt);
  void DispatchPendingWindowsMediaPlaybackActions();
  void InitializeShellNotificationIcon();
  void CleanupShellNotificationIcon();
  bool ShowTransferNotification(
      const std::wstring& title,
      const std::wstring& body,
      const std::wstring& destination_path);
  bool ShowNotification(
      const std::wstring& title,
      const std::wstring& body,
      const std::string& route,
      const flutter::EncodableMap& payload,
      const std::wstring& destination_path,
      const std::string& notification_key,
      const std::vector<uint8_t>& icon_bytes);
  bool ClearNotification(const std::string& notification_key);
  void DispatchPendingNotificationAction();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      clipboard_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      clipboard_event_sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_shell_method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      windows_media_playback_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      windows_media_playback_event_sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_media_playback_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      send_files_method_channel_;
  flutter::EncodableList pending_send_files_;
  bool send_files_channel_ready_ = false;
  bool clipboard_listener_registered_ = false;
  bool shell_notification_icon_registered_ = false;
  bool windows_media_playback_observing_ = false;
  winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager
      observed_media_session_manager_{nullptr};
  std::optional<flutter::EncodableMap> last_observed_media_playback_;
  winrt::Windows::Media::SystemMediaTransportControls
      media_transport_controls_{nullptr};
  winrt::event_token media_playback_button_pressed_token_{};
  winrt::event_token media_playback_position_change_token_{};
  std::mutex media_playback_mutex_;
  std::string current_media_playback_source_device_id_;
  std::string current_media_playback_playback_id_;
  std::vector<flutter::EncodableValue> pending_media_playback_actions_;
  std::wstring pending_notification_destination_path_;
  std::string pending_notification_route_;
  flutter::EncodableMap pending_notification_payload_;
  std::string current_native_notification_key_;
  HICON current_native_notification_icon_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
