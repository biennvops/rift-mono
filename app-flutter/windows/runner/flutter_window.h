#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterClipboardEventChannel();
  void RegisterClipboardMethodChannel();
  void RegisterWindowsMediaPlaybackEventChannel();
  void RegisterWindowsMediaPlaybackMethodChannel();
  void InitializeWindowsMediaPlaybackObserver();
  void StartWindowsMediaPlaybackObservation();
  void StopWindowsMediaPlaybackObservation();
  void PollWindowsMediaPlayback();
  flutter::EncodableMap SnapshotWindowsMediaPlayback();
  flutter::EncodableMap BuildWindowsMediaPlaybackEvent(
      const std::string& event_type,
      const flutter::EncodableMap& snapshot) const;
  flutter::EncodableMap BuildWindowsMediaPlaybackRemovedEvent() const;
  std::optional<flutter::EncodableMap> PerformWindowsMediaPlaybackAction(
      const std::string& action,
      std::optional<int64_t> position_ms);
  std::string GetWindowsPlaybackId() const;
  void RegisterWindowsShellMethodChannel();
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
      const std::wstring& destination_path);
  bool ShowMediaPlayback(const flutter::EncodableMap& playback);
  bool ClearMediaPlayback();
  void UpdateRemoteMediaPlaybackControls(const flutter::EncodableMap& playback);
  void DispatchPendingNotificationAction();
  void DispatchPendingMediaPlaybackAction();

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
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      windows_media_playback_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      windows_media_playback_event_sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_media_playback_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_shell_method_channel_;
  UINT_PTR windows_media_playback_timer_id_ = 0;
  bool windows_media_playback_observing_ = false;
  std::optional<flutter::EncodableMap> last_windows_media_playback_snapshot_;
  std::string current_windows_playback_id_;
  bool clipboard_listener_registered_ = false;
  bool shell_notification_icon_registered_ = false;
  std::wstring pending_notification_destination_path_;
  std::string pending_notification_route_;
  flutter::EncodableMap pending_notification_payload_;
  flutter::EncodableMap pending_media_playback_action_payload_;
  flutter::EncodableMap active_remote_media_playback_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
