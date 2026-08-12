#include "windows_notification_listener.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <appmodel.h>
#include <VersionHelpers.h>

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.UI.Notifications.Management.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <deque>
#include <functional>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>

#include "utils.h"
#include "windows_image_utils.h"

constexpr size_t kMaxNotificationIconBytes = 131072;
constexpr uint32_t kMaxNotificationIconDimension = 128;
constexpr uint32_t kRequestedNotificationIconDimension = 128;
constexpr uint64_t kMaxSourceLogoBytes = 4 * 1024 * 1024;
constexpr size_t kLogoCacheMaxEntries = 64;
constexpr size_t kMaxTitleCharacters = 256;
constexpr size_t kMaxBodyCharacters = 1024;

using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;
using UserNotification =
    winrt::Windows::UI::Notifications::UserNotification;
using UserNotificationChangedKind =
    winrt::Windows::UI::Notifications::UserNotificationChangedKind;
using UserNotificationListener =
    winrt::Windows::UI::Notifications::Management::UserNotificationListener;
using UserNotificationListenerAccessStatus =
    winrt::Windows::UI::Notifications::Management::UserNotificationListenerAccessStatus;

struct RuntimeInfo {
  bool supported = false;
  bool has_package_identity = false;
  std::wstring app_user_model_id;
  std::wstring package_family_name;
};

struct WindowsNotificationListener::State {
  struct PendingChange {
    UserNotificationChangedKind kind;
    uint32_t notification_id;
    uint64_t generation;
  };

  HWND window = nullptr;
  bool accepting_events = false;
  bool started = false;
  uint64_t listener_generation = 0;
  std::mutex gate;
  UserNotificationListener listener{nullptr};
  winrt::event_token notification_changed_token{};
  RuntimeInfo runtime;
  std::unordered_map<std::wstring, std::vector<uint8_t>> logo_cache;
  std::deque<std::wstring> logo_order;
  std::unordered_set<uint32_t> ignored_notification_ids;
  std::deque<PendingChange> pending_changes;
  bool processing_changes = false;
};

namespace {

bool IsWindowsBuildAtLeast(DWORD build_number) {
  if (!IsWindows10OrGreater()) {
    return false;
  }

  OSVERSIONINFOEXW version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  version.dwMajorVersion = 10;
  version.dwMinorVersion = 0;
  version.dwBuildNumber = build_number;
  DWORDLONG condition_mask = 0;
  condition_mask = VerSetConditionMask(condition_mask, VER_MAJORVERSION,
                                       VER_GREATER_EQUAL);
  condition_mask = VerSetConditionMask(condition_mask, VER_MINORVERSION,
                                       VER_GREATER_EQUAL);
  condition_mask = VerSetConditionMask(condition_mask, VER_BUILDNUMBER,
                                       VER_GREATER_EQUAL);
  return VerifyVersionInfoW(&version,
                            VER_MAJORVERSION | VER_MINORVERSION |
                                VER_BUILDNUMBER,
                            condition_mask) != FALSE;
}

bool ReadPackageString(
    LONG(WINAPI* getter)(UINT32*, PWSTR),
    std::wstring* value) {
  if (value == nullptr) {
    return false;
  }

  UINT32 length = 0;
  LONG status = getter(&length, nullptr);
  if (status != ERROR_INSUFFICIENT_BUFFER || length == 0) {
    return false;
  }

  std::vector<wchar_t> buffer(length);
  status = getter(&length, buffer.data());
  if (status != ERROR_SUCCESS) {
    return false;
  }
  value->assign(buffer.data());
  return true;
}

RuntimeInfo GetRuntimeInfo() {
  RuntimeInfo info;
  info.supported = IsWindowsBuildAtLeast(19041);
  if (!info.supported) {
    return info;
  }

  std::wstring package_name;
  info.has_package_identity = ReadPackageString(
      &GetCurrentPackageFullName, &package_name);
  if (!info.has_package_identity) {
    return info;
  }

  ReadPackageString(&GetCurrentApplicationUserModelId,
                    &info.app_user_model_id);
  ReadPackageString(&GetCurrentPackageFamilyName,
                    &info.package_family_name);
  return info;
}

std::string AccessStatusToString(UserNotificationListenerAccessStatus status) {
  switch (status) {
    case UserNotificationListenerAccessStatus::Allowed:
      return "allowed";
    case UserNotificationListenerAccessStatus::Denied:
      return "denied";
    case UserNotificationListenerAccessStatus::Unspecified:
      return "unspecified";
    default:
      return "error";
  }
}

std::wstring BoundText(const std::wstring& value, size_t max_characters) {
  if (value.size() <= max_characters) {
    return value;
  }
  return value.substr(0, max_characters);
}

std::string UtcIso8601(winrt::Windows::Foundation::DateTime value) {
  const auto time = winrt::clock::to_time_t(value);
  std::tm utc = {};
  if (gmtime_s(&utc, &time) != 0) {
    return {};
  }

  char buffer[32] = {};
  if (std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc) ==
      0) {
    return {};
  }
  return buffer;
}

std::string Utf8(const std::wstring& value) {
  return Utf8FromUtf16(value.c_str());
}

std::wstring HStringValue(const winrt::hstring& value) {
  return std::wstring(value.c_str(), value.size());
}

bool IsRiftApp(const RuntimeInfo& runtime,
               const std::wstring& app_user_model_id,
               const std::wstring& package_family_name) {
  return (!runtime.app_user_model_id.empty() &&
          runtime.app_user_model_id == app_user_model_id) ||
         (!runtime.package_family_name.empty() &&
          runtime.package_family_name == package_family_name);
}

void AddString(EncodableMap* map,
               const char* key,
               const std::string& value) {
  if (map != nullptr && !value.empty()) {
    (*map)[EncodableValue(key)] = EncodableValue(value);
  }
}

std::optional<int64_t> FindInt64(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  return std::nullopt;
}

EncodableValue RemovalResult(const char* status,
                             const std::string& message = {}) {
  EncodableMap result;
  result[EncodableValue("status")] = EncodableValue(status);
  AddString(&result, "message", message);
  return EncodableValue(result);
}

struct PostedEvent {
  uint64_t generation;
  EncodableValue value;
};

bool IsCurrentGeneration(
    const std::shared_ptr<WindowsNotificationListener::State>& state,
    uint64_t generation) {
  std::lock_guard<std::mutex> lock(state->gate);
  return state->listener_generation == generation;
}

std::optional<std::vector<uint8_t>> CachedLogo(
    const std::shared_ptr<WindowsNotificationListener::State>& state,
    const std::wstring& key) {
  std::lock_guard<std::mutex> lock(state->gate);
  const auto cached = state->logo_cache.find(key);
  if (cached == state->logo_cache.end()) {
    return std::nullopt;
  }
  return cached->second;
}

void CacheLogo(const std::shared_ptr<WindowsNotificationListener::State>& state,
               const std::wstring& key,
               const std::vector<uint8_t>& logo) {
  std::lock_guard<std::mutex> lock(state->gate);
  if (state->logo_cache.find(key) == state->logo_cache.end() &&
      state->logo_cache.size() >= kLogoCacheMaxEntries) {
    const auto oldest = state->logo_order.front();
    state->logo_order.pop_front();
    state->logo_cache.erase(oldest);
  }
  state->logo_cache[key] = logo;
  state->logo_order.push_back(key);
}

void PostEvent(const std::shared_ptr<WindowsNotificationListener::State>& state,
              uint64_t generation,
              EncodableMap event) {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(state->gate);
    if (!state->accepting_events ||
        state->listener_generation != generation || state->window == nullptr) {
      return;
    }
    window = state->window;
  }

  auto* payload = new PostedEvent{
      generation, EncodableValue(std::move(event))};
  if (!PostMessageW(window, WindowsNotificationListener::kEventMessage, 0,
                    reinterpret_cast<LPARAM>(payload))) {
    delete payload;
  }
}

}  // namespace

WindowsNotificationListener::WindowsNotificationListener(
    flutter::BinaryMessenger* messenger,
    HWND window)
    : messenger_(messenger), state_(std::make_shared<State>()) {
  state_->window = window;
  state_->runtime = GetRuntimeInfo();
}

WindowsNotificationListener::~WindowsNotificationListener() {
  OnDestroy();
}

void WindowsNotificationListener::RegisterChannels() {
  if (messenger_ == nullptr || method_channel_ != nullptr ||
      event_channel_ != nullptr) {
    return;
  }

  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger_, "rift/windows/notification_listener",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<MethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger_, "rift/windows/notification_listener_events",
      &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
            event_sink_ = std::move(sink);
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          },
          [this](const EncodableValue*) {
            event_sink_.reset();
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          }));
}

void WindowsNotificationListener::OnDestroy() {
  auto state = state_;
  if (state == nullptr) {
    return;
  }

  winrt::event_token token{};
  UserNotificationListener listener{nullptr};
  bool was_started = false;
  {
    std::lock_guard<std::mutex> lock(state->gate);
    state->accepting_events = false;
    state->listener_generation++;
    state->pending_changes.clear();
    state->processing_changes = false;
    state->ignored_notification_ids.clear();
    state->window = nullptr;
    was_started = state->started;
    state->started = false;
    token = state->notification_changed_token;
    listener = state->listener;
  }

  if (was_started && listener != nullptr) {
    try {
      listener.NotificationChanged(token);
    } catch (...) {
    }
  }

  event_sink_.reset();
  event_channel_.reset();
  method_channel_.reset();
}

bool WindowsNotificationListener::HandleWindowMessage(UINT message,
                                                        LPARAM lparam) {
  if (message != kEventMessage) {
    return false;
  }

  auto* payload = reinterpret_cast<PostedEvent*>(lparam);
  if (payload != nullptr) {
    bool current_generation = false;
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      current_generation =
          state_->accepting_events &&
          state_->listener_generation == payload->generation;
    }
    if (current_generation && event_sink_ != nullptr) {
      event_sink_->Success(payload->value);
    }
    delete payload;
  }
  return true;
}

void WindowsNotificationListener::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult> result) {
  const auto& method = call.method_name();
  if (method == "getRuntimeStatus") {
    GetRuntimeStatus(std::move(result));
  } else if (method == "getAccessStatus") {
    GetAccessStatus(std::move(result));
  } else if (method == "requestAccess") {
    RequestAccess(std::move(result));
  } else if (method == "listActive") {
    ListActive(std::move(result));
  } else if (method == "removeNotification") {
    RemoveNotification(call.arguments(), std::move(result));
  } else if (method == "start") {
    Start(std::move(result));
  } else if (method == "stop") {
    Stop(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void WindowsNotificationListener::GetRuntimeStatus(
    std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
  }

  EncodableMap status;
  status[EncodableValue("supported")] = EncodableValue(runtime.supported);
  status[EncodableValue("hasPackageIdentity")] =
      EncodableValue(runtime.has_package_identity);
  AddString(&status, "appUserModelId", Utf8(runtime.app_user_model_id));
  AddString(&status, "packageFamilyName", Utf8(runtime.package_family_name));
  result->Success(EncodableValue(status));
}

void WindowsNotificationListener::GetAccessStatus(
    std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
  }
  if (!runtime.supported) {
    result->Success(EncodableValue(std::string("unsupported")));
    return;
  }
  if (!runtime.has_package_identity) {
    result->Success(EncodableValue(std::string("unpackaged")));
    return;
  }

  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      listener = state_->listener;
    }
    if (listener == nullptr) {
      listener = UserNotificationListener::Current();
      std::lock_guard<std::mutex> lock(state_->gate);
      state_->listener = listener;
    }
    result->Success(EncodableValue(AccessStatusToString(
        listener.GetAccessStatus())));
  } catch (...) {
    result->Success(EncodableValue(std::string("error")));
  }
}

void WindowsNotificationListener::RequestAccess(
    std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
  }
  if (!runtime.supported) {
    result->Success(EncodableValue(std::string("unsupported")));
    return;
  }
  if (!runtime.has_package_identity) {
    result->Success(EncodableValue(std::string("unpackaged")));
    return;
  }

  auto result_holder = std::shared_ptr<MethodResult>(result.release());
  RequestAccessAsync(state_, std::move(result_holder));
}

winrt::fire_and_forget WindowsNotificationListener::RequestAccessAsync(
    std::shared_ptr<State> state,
    std::shared_ptr<MethodResult> result) {
  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state->gate);
      listener = state->listener;
    }
    if (listener == nullptr) {
      listener = UserNotificationListener::Current();
      std::lock_guard<std::mutex> lock(state->gate);
      state->listener = listener;
    }

    const auto status = co_await listener.RequestAccessAsync();
    result->Success(EncodableValue(AccessStatusToString(status)));
  } catch (...) {
    result->Success(EncodableValue(std::string("error")));
  }
}

void WindowsNotificationListener::ListActive(
    std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  uint64_t generation = 0;
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
    generation = state_->listener_generation;
  }
  if (!runtime.supported || !runtime.has_package_identity) {
    result->Success(EncodableValue(flutter::EncodableList()));
    return;
  }

  auto result_holder = std::shared_ptr<MethodResult>(result.release());
  ListActiveAsync(state_, generation, std::move(result_holder));
}

winrt::fire_and_forget WindowsNotificationListener::ListActiveAsync(
    std::shared_ptr<State> state,
    uint64_t generation,
    std::shared_ptr<MethodResult> result) {
  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state->gate);
      listener = state->listener;
    }
    if (listener == nullptr) {
      listener = UserNotificationListener::Current();
      std::lock_guard<std::mutex> lock(state->gate);
      state->listener = listener;
    }
    if (listener.GetAccessStatus() !=
        UserNotificationListenerAccessStatus::Allowed) {
      result->Success(EncodableValue(flutter::EncodableList()));
      co_return;
    }

    const auto notifications = co_await listener.GetNotificationsAsync(
        winrt::Windows::UI::Notifications::NotificationKinds::Toast);
    auto items = std::make_shared<
        std::vector<UserNotification>>();
    items->reserve(notifications.Size());
    for (uint32_t index = 0; index < notifications.Size(); ++index) {
      items->push_back(notifications.GetAt(index));
    }

    auto entries = std::make_shared<flutter::EncodableList>();
    auto next = std::make_shared<std::function<void(size_t)>>();
    auto weak_next = std::weak_ptr<std::function<void(size_t)>>(next);
    *next = [state, generation, items, entries, result, weak_next](
                size_t index) {
      const auto strong_next = weak_next.lock();
      if (strong_next == nullptr) {
        return;
      }
      WindowsNotificationListener::ContinueListActive(
          state, generation, items, index, entries, result, strong_next);
    };
    (*next)(0);
  } catch (...) {
    result->Success(EncodableValue(flutter::EncodableList()));
  }
}

void WindowsNotificationListener::ContinueListActive(
    std::shared_ptr<State> state,
    uint64_t generation,
    std::shared_ptr<std::vector<UserNotification>> notifications,
    size_t index,
    std::shared_ptr<flutter::EncodableList> entries,
    std::shared_ptr<MethodResult> result,
    std::shared_ptr<std::function<void(size_t)>> next) {
  if (index >= notifications->size()) {
    result->Success(EncodableValue(*entries));
    return;
  }

  const auto notification = (*notifications)[index];
  BuildNotificationAsync(
      state, generation, notification,
      [state, entries, result, next, index](
          std::optional<EncodableMap> item) {
        if (item.has_value()) {
          entries->push_back(EncodableValue(std::move(item.value())));
        }
        (*next)(index + 1);
      });
}

void WindowsNotificationListener::RemoveNotification(
    const EncodableValue* arguments,
    std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
  }
  if (!runtime.supported || !runtime.has_package_identity) {
    result->Success(RemovalResult("unavailable"));
    return;
  }

  const auto* arguments_map =
      arguments == nullptr ? nullptr : std::get_if<EncodableMap>(arguments);
  const auto notification_id = arguments_map == nullptr
                                   ? std::nullopt
                                   : FindInt64(*arguments_map,
                                               "userNotificationId");
  if (!notification_id.has_value() || notification_id.value() < 0 ||
      notification_id.value() > std::numeric_limits<uint32_t>::max()) {
    result->Success(RemovalResult("unavailable"));
    return;
  }

  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      listener = state_->listener;
    }
    if (listener == nullptr) {
      listener = UserNotificationListener::Current();
      std::lock_guard<std::mutex> lock(state_->gate);
      state_->listener = listener;
    }
    if (listener.GetAccessStatus() !=
        UserNotificationListenerAccessStatus::Allowed) {
      result->Success(RemovalResult("unavailable"));
      return;
    }

    const auto id = static_cast<uint32_t>(notification_id.value());
    const auto notification = listener.GetNotification(id);
    if (notification == nullptr) {
      result->Success(RemovalResult("notFound"));
      return;
    }
    listener.RemoveNotification(id);
    result->Success(RemovalResult("success"));
  } catch (const winrt::hresult_error&) {
    result->Success(RemovalResult("error"));
  } catch (...) {
    result->Success(RemovalResult("error"));
  }
}

void WindowsNotificationListener::Start(std::unique_ptr<MethodResult> result) {
  const auto runtime = GetRuntimeInfo();
  {
    std::lock_guard<std::mutex> lock(state_->gate);
    state_->runtime = runtime;
  }
  if (!runtime.supported || !runtime.has_package_identity) {
    result->Success(EncodableValue(false));
    return;
  }

  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      listener = state_->listener;
    }
    if (listener == nullptr) {
      listener = UserNotificationListener::Current();
      std::lock_guard<std::mutex> lock(state_->gate);
      state_->listener = listener;
    }
    if (listener.GetAccessStatus() !=
        UserNotificationListenerAccessStatus::Allowed) {
      result->Success(EncodableValue(false));
      return;
    }

    uint64_t generation = 0;
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      if (state_->started) {
        result->Success(EncodableValue(true));
        return;
      }
      generation = ++state_->listener_generation;
      state_->accepting_events = false;
      state_->pending_changes.clear();
      state_->processing_changes = false;
      state_->ignored_notification_ids.clear();
    }

    const auto token = listener.NotificationChanged(
        [state = state_, generation](
            UserNotificationListener const&,
            winrt::Windows::UI::Notifications::UserNotificationChangedEventArgs const& args) {
          WindowsNotificationListener::QueueNotificationChange(
              state, generation, args.ChangeKind(), args.UserNotificationId());
        });
    bool installed = false;
    {
      std::lock_guard<std::mutex> lock(state_->gate);
      if (state_->listener_generation == generation && !state_->started) {
        state_->notification_changed_token = token;
        state_->started = true;
        state_->accepting_events = true;
        installed = true;
      }
    }
    if (!installed) {
      try {
        listener.NotificationChanged(token);
      } catch (...) {
      }
      result->Success(EncodableValue(false));
      return;
    }
    result->Success(EncodableValue(true));
  } catch (...) {
    result->Success(EncodableValue(false));
  }
}

void WindowsNotificationListener::Stop(std::unique_ptr<MethodResult> result) {
  auto state = state_;
  winrt::event_token token{};
  UserNotificationListener listener{nullptr};
  bool was_started = false;
  {
    std::lock_guard<std::mutex> lock(state->gate);
    state->accepting_events = false;
    state->listener_generation++;
    state->pending_changes.clear();
    state->processing_changes = false;
    state->ignored_notification_ids.clear();
    was_started = state->started;
    state->started = false;
    token = state->notification_changed_token;
    listener = state->listener;
  }

  if (was_started && listener != nullptr) {
    try {
      listener.NotificationChanged(token);
    } catch (...) {
    }
  }
  result->Success(EncodableValue(true));
}

void WindowsNotificationListener::QueueNotificationChange(
    std::shared_ptr<State> state,
    uint64_t generation,
    UserNotificationChangedKind kind,
    uint32_t notification_id) {
  bool should_start = false;
  {
    std::lock_guard<std::mutex> lock(state->gate);
    if (!state->accepting_events || !state->started ||
        state->listener_generation != generation) {
      return;
    }
    state->pending_changes.push_back(
        State::PendingChange{kind, notification_id, generation});
    if (!state->processing_changes) {
      state->processing_changes = true;
      should_start = true;
    }
  }
  if (should_start) {
    DrainNotificationChanges(std::move(state), generation);
  }
}

void WindowsNotificationListener::DrainNotificationChanges(
    std::shared_ptr<State> state,
    uint64_t generation) {
  State::PendingChange change{};
  {
    std::lock_guard<std::mutex> lock(state->gate);
    if (state->listener_generation != generation ||
        !state->accepting_events || !state->started) {
      if (state->listener_generation == generation) {
        state->pending_changes.clear();
        state->processing_changes = false;
      }
      return;
    }
    if (state->pending_changes.empty()) {
      state->processing_changes = false;
      return;
    }
    change = state->pending_changes.front();
    state->pending_changes.pop_front();
  }

  const auto kind = change.kind;
  const auto notification_id = change.notification_id;
  if (kind == UserNotificationChangedKind::Removed) {
    bool ignored = false;
    {
      std::lock_guard<std::mutex> lock(state->gate);
      if (state->listener_generation != generation) {
        return;
      }
      ignored = state->ignored_notification_ids.erase(notification_id) != 0;
    }
    if (!ignored) {
      EncodableMap event;
      event[EncodableValue("eventType")] = EncodableValue("removed");
      event[EncodableValue("userNotificationId")] =
          EncodableValue(static_cast<int64_t>(notification_id));
      event[EncodableValue("notificationId")] =
          EncodableValue("windows:" + std::to_string(notification_id));
      AddString(&event, "removedAt", UtcIso8601(winrt::clock::now()));
      PostEvent(state, generation, std::move(event));
    }
    DrainNotificationChanges(std::move(state), generation);
    return;
  }

  try {
    UserNotificationListener listener{nullptr};
    {
      std::lock_guard<std::mutex> lock(state->gate);
      listener = state->listener;
    }
    if (listener == nullptr) {
      DrainNotificationChanges(std::move(state), generation);
      return;
    }
    const auto notification = listener.GetNotification(notification_id);
    if (notification == nullptr) {
      DrainNotificationChanges(std::move(state), generation);
      return;
    }

    BuildNotificationAsync(
        state, generation, notification,
        [state, generation](std::optional<EncodableMap> event) {
          if (event.has_value()) {
            PostEvent(state, generation, std::move(event.value()));
          }
          DrainNotificationChanges(std::move(state), generation);
        });
  } catch (...) {
    DrainNotificationChanges(std::move(state), generation);
  }
}

winrt::fire_and_forget WindowsNotificationListener::BuildNotificationAsync(
    std::shared_ptr<State> state,
    uint64_t generation,
    UserNotification notification,
    NotificationCallback callback) {
  std::optional<EncodableMap> event;
  try {
    if (!IsCurrentGeneration(state, generation)) {
      callback(std::nullopt);
      co_return;
    }

    const auto app_info = notification.AppInfo();
    if (app_info == nullptr) {
      callback(std::nullopt);
      co_return;
    }

    const auto app_user_model_id = HStringValue(app_info.AppUserModelId());
    const auto package_family_name = HStringValue(app_info.PackageFamilyName());
    RuntimeInfo runtime;
    {
      std::lock_guard<std::mutex> lock(state->gate);
      runtime = state->runtime;
    }
    if (IsRiftApp(runtime, app_user_model_id, package_family_name)) {
      {
        std::lock_guard<std::mutex> lock(state->gate);
        if (state->listener_generation == generation) {
          state->ignored_notification_ids.insert(notification.Id());
        }
      }
      // The callback advances the serialized queue and may re-enter gate.
      callback(std::nullopt);
      co_return;
    }

    std::wstring package_name = app_user_model_id;
    if (package_name.empty()) {
      package_name = package_family_name;
    }
    if (package_name.empty()) {
      package_name = HStringValue(app_info.Id());
    }
    if (package_name.empty()) {
      package_name = L"windows.unknown";
    }

    std::wstring app_name;
    try {
      app_name = HStringValue(app_info.DisplayInfo().DisplayName());
    } catch (...) {
    }
    if (app_name.empty()) {
      app_name = package_name;
    }
    if (app_name.empty()) {
      app_name = L"Windows application";
    }

    std::wstring title;
    std::wstring body;
    try {
      const auto visual = notification.Notification().Visual();
      const auto binding = visual.GetBinding(
          winrt::Windows::UI::Notifications::KnownNotificationBindings::ToastGeneric());
      if (binding != nullptr) {
        const auto text_elements = binding.GetTextElements();
        for (uint32_t index = 0; index < text_elements.Size(); ++index) {
          const auto text = HStringValue(text_elements.GetAt(index).Text());
          if (index == 0) {
            title = text;
          } else {
            if (!body.empty()) {
              body.append(L"\n");
            }
            body.append(text);
          }
        }
      }
    } catch (...) {
    }
    title = BoundText(title, kMaxTitleCharacters);
    body = BoundText(body, kMaxBodyCharacters);

    std::vector<uint8_t> icon;
    const auto cached = CachedLogo(state, package_name);
    if (cached.has_value()) {
      icon = std::move(cached.value());
    } else {
      try {
        const auto logo_reference = app_info.DisplayInfo().GetLogo(
            winrt::Windows::Foundation::Size{
                static_cast<float>(kRequestedNotificationIconDimension),
                static_cast<float>(kRequestedNotificationIconDimension)});
        if (logo_reference != nullptr) {
          const auto stream = co_await logo_reference.OpenReadAsync();
          const auto source_size = stream.Size();
          if (source_size > 0 && source_size <= kMaxSourceLogoBytes &&
              source_size <= std::numeric_limits<uint32_t>::max()) {
            winrt::Windows::Storage::Streams::DataReader reader(stream);
            const auto loaded = co_await reader.LoadAsync(
                static_cast<uint32_t>(source_size));
            if (loaded > 0) {
              std::vector<uint8_t> raw(loaded);
              reader.ReadBytes(raw);
              if (NormalizeImageToPng(raw, kMaxNotificationIconDimension,
                                      kMaxNotificationIconBytes, &icon)) {
                CacheLogo(state, package_name, icon);
              }
            }
          }
        }
      } catch (...) {
        icon.clear();
      }
    }

    EncodableMap normalized;
    normalized[EncodableValue("eventType")] = EncodableValue("posted");
    normalized[EncodableValue("userNotificationId")] =
        EncodableValue(static_cast<int64_t>(notification.Id()));
    normalized[EncodableValue("notificationId")] = EncodableValue(
        "windows:" + std::to_string(notification.Id()));
    AddString(&normalized, "packageName", Utf8(package_name));
    AddString(&normalized, "appName", Utf8(app_name));
    AddString(&normalized, "title", Utf8(title));
    AddString(&normalized, "bodyPreview", Utf8(body));
    AddString(&normalized, "postedAt", UtcIso8601(notification.CreationTime()));
    if (!icon.empty()) {
      normalized[EncodableValue("iconBytes")] = EncodableValue(icon);
    }
    event = std::move(normalized);
  } catch (...) {
    event = std::nullopt;
  }
  if (!IsCurrentGeneration(state, generation)) {
    callback(std::nullopt);
    co_return;
  }
  callback(std::move(event));
}
