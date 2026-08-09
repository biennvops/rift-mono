#ifndef RUNNER_WINDOWS_NOTIFICATION_LISTENER_H_
#define RUNNER_WINDOWS_NOTIFICATION_LISTENER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <winrt/Windows.UI.Notifications.Management.h>
#include <winrt/base.h>

#include <functional>
#include <memory>
#include <optional>
#include <vector>

// Bridges UserNotificationListener to Flutter without coupling notification
// capture to the WindowsShell notification-display channel.
class WindowsNotificationListener {
 public:
  // This message carries a heap-owned EncodableValue from a WinRT callback to
  // the Flutter runner's UI message loop.
  static constexpr UINT kEventMessage = WM_APP + 17;

  struct State;

  WindowsNotificationListener(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsNotificationListener();

  void RegisterChannels();
  void OnDestroy();
  bool HandleWindowMessage(UINT message, LPARAM lparam);

 private:
  using EncodableValue = flutter::EncodableValue;
  using MethodResult = flutter::MethodResult<EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<MethodResult> result);
  void GetRuntimeStatus(std::unique_ptr<MethodResult> result);
  void GetAccessStatus(std::unique_ptr<MethodResult> result);
  void RequestAccess(std::unique_ptr<MethodResult> result);
  void ListActive(std::unique_ptr<MethodResult> result);
  void Start(std::unique_ptr<MethodResult> result);
  void Stop(std::unique_ptr<MethodResult> result);

  using NotificationCallback =
      std::function<void(std::optional<flutter::EncodableMap>)>;

  static winrt::fire_and_forget RequestAccessAsync(
      std::shared_ptr<State> state,
      std::shared_ptr<MethodResult> result);
  static winrt::fire_and_forget ListActiveAsync(
      std::shared_ptr<State> state,
      std::shared_ptr<MethodResult> result);
  static void ContinueListActive(
      std::shared_ptr<State> state,
      std::shared_ptr<std::vector<winrt::Windows::UI::Notifications::UserNotification>> notifications,
      size_t index,
      std::shared_ptr<flutter::EncodableList> entries,
      std::shared_ptr<MethodResult> result,
      std::shared_ptr<std::function<void(size_t)>> next);
  static winrt::fire_and_forget ProcessNotificationChangeAsync(
      std::shared_ptr<State> state,
      winrt::Windows::UI::Notifications::UserNotificationChangedKind kind,
      uint32_t notification_id);
  static winrt::fire_and_forget BuildNotificationAsync(
      std::shared_ptr<State> state,
      winrt::Windows::UI::Notifications::UserNotification notification,
      NotificationCallback callback);

  flutter::BinaryMessenger* messenger_;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
};

#endif  // RUNNER_WINDOWS_NOTIFICATION_LISTENER_H_
