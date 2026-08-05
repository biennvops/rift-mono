#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cstring>

namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus

#pragma warning(push)
#pragma warning(disable : 4458)
#include <gdiplus.h>
#pragma warning(pop)
#include <limits>
#include <future>
#include <objidl.h>
#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>
#include <wincodec.h>
#include <wrl/client.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kRiftShellNotifyMessage = WM_APP + 1;
constexpr UINT kRiftMediaPlaybackActionMessage = WM_APP + 2;

struct PostedMediaPlaybackAction {
  flutter::EncodableMap payload;
};
// tray_manager owns icon 1 and WM_USER + 1. Native balloons temporarily
// borrow that icon so Rift has only one notification-area entry.
constexpr UINT kTrayManagerNotifyMessage = WM_USER + 1;
constexpr UINT kRiftShellNotifyId = 1;
// WM_COPYDATA identifier for file handoff from a second app instance.
constexpr ULONG_PTR kRiftSendFilesCopyDataId = 0x52465446;  // 'RFTF'
constexpr int kClipboardOpenAttempts = 10;
constexpr DWORD kClipboardOpenRetryDelayMs = 25;

std::wstring Utf16FromUtf8(const std::string& utf8_string);

void LogClipboardMessage(const std::string& message) {
  std::wstring wide_message = Utf16FromUtf8(message);
  if (!wide_message.empty()) {
    OutputDebugStringW((L"Rift clipboard bridge: " + wide_message + L"\n").c_str());
  }
}

bool OpenClipboardForWriteWithRetry(HWND owner) {
  for (int attempt = 0; attempt < kClipboardOpenAttempts; ++attempt) {
    if (OpenClipboard(owner)) {
      return true;
    }
    if (attempt + 1 < kClipboardOpenAttempts) {
      Sleep(kClipboardOpenRetryDelayMs);
    }
  }
  return false;
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

bool ReadDibAsPng(HGLOBAL handle, std::vector<uint8_t>* png_bytes) {
  if (handle == nullptr || png_bytes == nullptr) {
    return false;
  }

  const SIZE_T size = GlobalSize(handle);
  if (size < sizeof(BITMAPINFOHEADER)) {
    return false;
  }

  const auto* dib = static_cast<const uint8_t*>(GlobalLock(handle));
  if (dib == nullptr) {
    return false;
  }

  const auto* header = reinterpret_cast<const BITMAPINFOHEADER*>(dib);
  const size_t header_size = header->biSize;
  const size_t mask_size =
      header->biCompression == BI_BITFIELDS && header_size == sizeof(BITMAPINFOHEADER)
          ? 3 * sizeof(DWORD)
          : 0;
  const size_t color_count = header->biBitCount <= 8
                                 ? (header->biClrUsed != 0
                                        ? header->biClrUsed
                                        : (1u << header->biBitCount))
                                 : 0;
  const size_t pixel_offset =
      header_size + mask_size + color_count * sizeof(RGBQUAD);
  if (header_size < sizeof(BITMAPINFOHEADER) || pixel_offset > size ||
      header->biWidth <= 0 || header->biHeight == 0 || header->biPlanes != 1) {
    GlobalUnlock(handle);
    return false;
  }

  HDC screen_dc = GetDC(nullptr);
  HBITMAP bitmap = CreateDIBitmap(
      screen_dc, header, CBM_INIT, dib + pixel_offset,
      reinterpret_cast<const BITMAPINFO*>(dib), DIB_RGB_COLORS);
  ReleaseDC(nullptr, screen_dc);
  GlobalUnlock(handle);
  if (bitmap == nullptr) {
    return false;
  }

  Gdiplus::GdiplusStartupInput startup_input;
  ULONG_PTR startup_token = 0;
  if (Gdiplus::GdiplusStartup(&startup_token, &startup_input, nullptr) !=
      Gdiplus::Ok) {
    DeleteObject(bitmap);
    return false;
  }

  bool success = false;
  {
    Gdiplus::Bitmap image(bitmap, nullptr);
    UINT encoder_count = 0;
    UINT encoder_bytes = 0;
    if (image.GetLastStatus() == Gdiplus::Ok &&
        Gdiplus::GetImageEncodersSize(&encoder_count, &encoder_bytes) ==
            Gdiplus::Ok) {
      std::vector<uint8_t> encoder_buffer(encoder_bytes);
      auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(
          encoder_buffer.data());
      if (Gdiplus::GetImageEncoders(encoder_count, encoder_bytes, encoders) ==
          Gdiplus::Ok) {
        CLSID png_encoder = {};
        for (UINT i = 0; i < encoder_count; ++i) {
          if (wcscmp(encoders[i].MimeType, L"image/png") == 0) {
            png_encoder = encoders[i].Clsid;
            break;
          }
        }

        IStream* stream = nullptr;
        if (png_encoder.Data1 != 0 &&
            SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
          if (image.Save(stream, &png_encoder, nullptr) == Gdiplus::Ok) {
            STATSTG stat = {};
            LARGE_INTEGER origin = {};
            if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
                stat.cbSize.QuadPart <=
                    static_cast<ULONGLONG>(std::numeric_limits<size_t>::max()) &&
                stat.cbSize.QuadPart <= std::numeric_limits<ULONG>::max() &&
                SUCCEEDED(stream->Seek(origin, STREAM_SEEK_SET, nullptr))) {
              png_bytes->resize(static_cast<size_t>(stat.cbSize.QuadPart));
              ULONG bytes_read = 0;
              success = SUCCEEDED(stream->Read(
                                  png_bytes->data(),
                                  static_cast<ULONG>(png_bytes->size()),
                                  &bytes_read)) &&
                        bytes_read == png_bytes->size();
              if (!success) {
                png_bytes->clear();
              }
            }
          }
          stream->Release();
        }
      }
    }
  }

  Gdiplus::GdiplusShutdown(startup_token);
  DeleteObject(bitmap);
  return success;
}

HGLOBAL CreateDibV5FromPng(const std::vector<uint8_t>& png_bytes) {
  if (png_bytes.empty() ||
      png_bytes.size() > std::numeric_limits<DWORD>::max()) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(png_bytes.data()),
          static_cast<DWORD>(png_bytes.size())))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IWICBitmapFrameDecode> frame;
  Microsoft::WRL::ComPtr<IWICFormatConverter> converter;
  if (FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(
          frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
          nullptr, 0.0, WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 || height == 0 ||
      width > static_cast<UINT>(std::numeric_limits<LONG>::max()) ||
      height > static_cast<UINT>(std::numeric_limits<LONG>::max())) {
    return nullptr;
  }

  const uint64_t stride64 = static_cast<uint64_t>(width) * 4;
  const uint64_t image_size64 = stride64 * height;
  const uint64_t allocation_size64 = sizeof(BITMAPV5HEADER) + image_size64;
  if (stride64 > std::numeric_limits<UINT>::max() ||
      image_size64 > std::numeric_limits<UINT>::max() ||
      allocation_size64 > std::numeric_limits<SIZE_T>::max()) {
    return nullptr;
  }

  HGLOBAL memory =
      GlobalAlloc(GMEM_MOVEABLE, static_cast<SIZE_T>(allocation_size64));
  if (memory == nullptr) {
    return nullptr;
  }

  auto* header = static_cast<BITMAPV5HEADER*>(GlobalLock(memory));
  if (header == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }

  ZeroMemory(header, sizeof(BITMAPV5HEADER));
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = static_cast<LONG>(width);
  header->bV5Height = -static_cast<LONG>(height);
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = static_cast<DWORD>(image_size64);
  header->bV5RedMask = 0x00FF0000;
  header->bV5GreenMask = 0x0000FF00;
  header->bV5BlueMask = 0x000000FF;
  header->bV5AlphaMask = 0xFF000000;
  header->bV5CSType = LCS_sRGB;
  header->bV5Intent = LCS_GM_IMAGES;

  auto* pixels = reinterpret_cast<BYTE*>(header) + sizeof(BITMAPV5HEADER);
  const HRESULT copy_result = converter->CopyPixels(
      nullptr, static_cast<UINT>(stride64), static_cast<UINT>(image_size64),
      pixels);
  GlobalUnlock(memory);
  if (FAILED(copy_result)) {
    GlobalFree(memory);
    return nullptr;
  }

  return memory;
}

const std::string* FindString(const flutter::EncodableMap& map,
                              const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&it->second);
}

const bool* FindBool(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<bool>(&it->second);
}

std::optional<int64_t> FindInt64(const flutter::EncodableMap& map,
                                 const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  return std::nullopt;
}

bool IsTrue(const flutter::EncodableMap& map, const char* key) {
  const bool* value = FindBool(map, key);
  return value != nullptr && *value;
}

winrt::Windows::Storage::Streams::RandomAccessStreamReference
CreateArtworkReference(const flutter::EncodableMap& playback) {
  const auto artwork_it = playback.find(flutter::EncodableValue("artwork"));
  if (artwork_it == playback.end()) {
    return nullptr;
  }
  const auto* artwork = std::get_if<flutter::EncodableMap>(&artwork_it->second);
  if (artwork == nullptr) {
    return nullptr;
  }
  const std::string* media_type = FindString(*artwork, "mediaType");
  const std::string* data_base64 = FindString(*artwork, "dataBase64");
  if (media_type == nullptr || data_base64 == nullptr || data_base64->empty()) {
    return nullptr;
  }
  if (*media_type != "image/png" && *media_type != "image/jpeg" &&
      *media_type != "image/gif" && *media_type != "image/webp") {
    return nullptr;
  }

  try {
    const std::wstring data_base64_utf16 = Utf16FromUtf8(*data_base64);
    if (data_base64_utf16.empty()) {
      return nullptr;
    }

    return std::async(std::launch::async, [data_base64_utf16]() {
      try {
        winrt::init_apartment();
      } catch (...) {
      }

      auto stream =
          winrt::Windows::Storage::Streams::InMemoryRandomAccessStream();
      auto buffer =
          winrt::Windows::Security::Cryptography::CryptographicBuffer::
              DecodeFromBase64String(data_base64_utf16);
      auto writer = winrt::Windows::Storage::Streams::DataWriter(stream);
      writer.WriteBuffer(buffer);
      writer.StoreAsync().get();
      writer.FlushAsync().get();
      writer.DetachStream();
      stream.Seek(0);
      return winrt::Windows::Storage::Streams::RandomAccessStreamReference::
          CreateFromStream(stream);
    }).get();
  } catch (...) {
    return nullptr;
  }
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
  RegisterWindowsMediaPlaybackMethodChannel();
  RegisterSendFilesMethodChannel();
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
  windows_media_playback_method_channel_.reset();
  ClearWindowsMediaPlayback();
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
    case kRiftMediaPlaybackActionMessage:
      DispatchPostedWindowsMediaPlaybackAction(wparam);
      return 0;
    case kRiftShellNotifyMessage: {
      const UINT notification_event = LOWORD(lparam);
      if (notification_event == NIN_BALLOONUSERCLICK) {
        DispatchPendingNotificationAction();
        CleanupShellNotificationIcon();
        return 0;
      }
      if (notification_event == NIN_BALLOONHIDE ||
          notification_event == NIN_BALLOONTIMEOUT) {
        CleanupShellNotificationIcon();
        return 0;
      }
      if (notification_event == WM_LBUTTONUP) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        CleanupShellNotificationIcon();
        return 0;
      }
      if (notification_event == WM_RBUTTONUP) {
        CleanupShellNotificationIcon();
        PostMessageW(hwnd, kTrayManagerNotifyMessage, wparam, lparam);
        return 0;
      }
      break;
    }
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

          const UINT dib_format = IsClipboardFormatAvailable(CF_DIBV5)
                                      ? CF_DIBV5
                                      : CF_DIB;
          if (IsClipboardFormatAvailable(dib_format)) {
            HANDLE handle = GetClipboardData(dib_format);
            std::vector<uint8_t> bytes;
            if (ReadDibAsPng(handle, &bytes)) {
              CloseClipboard();
              LogClipboardMessage("read standard bitmap as image/png payload (" +
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
          HGLOBAL dib_memory = nullptr;
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
            dib_memory = CreateDibV5FromPng(*bytes);
          }
          if (*content_type != "text/plain" && *content_type != "clipboard" &&
              *content_type != "image/png") {
            LogClipboardMessage("unsupported write content type " + *content_type);
          }

          if (memory == nullptr && dib_memory == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }

          if (!OpenClipboardForWriteWithRetry(GetHandle())) {
            LogClipboardMessage("OpenClipboard failed for write after retries.");
            GlobalFree(memory);
            GlobalFree(dib_memory);
            result->Success(flutter::EncodableValue(false));
            return;
          }

          if (!EmptyClipboard()) {
            LogClipboardMessage("EmptyClipboard failed for write.");
            GlobalFree(memory);
            GlobalFree(dib_memory);
            CloseClipboard();
            result->Success(flutter::EncodableValue(false));
            return;
          }

          const bool primary_applied =
              memory != nullptr &&
              SetClipboardData(clipboard_format, memory) != nullptr;
          if (!primary_applied) {
            GlobalFree(memory);
          }
          applied = primary_applied;
          if (*content_type == "text/plain" || *content_type == "clipboard") {
            LogClipboardMessage(std::string("write text/plain payload (") +
                                std::to_string(bytes->size()) +
                                " bytes) success=" +
                                (applied ? "true" : "false"));
          } else if (*content_type == "image/png") {
            const bool dib_applied =
                dib_memory != nullptr &&
                SetClipboardData(CF_DIBV5, dib_memory) != nullptr;
            if (!dib_applied) {
              GlobalFree(dib_memory);
            }
            applied = primary_applied || dib_applied;
            LogClipboardMessage(std::string("write image/png payload (") +
                                std::to_string(bytes->size()) +
                                " bytes) png=" +
                                (primary_applied ? "true" : "false") +
                                " dibv5=" +
                                (dib_applied ? "true" : "false"));
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
        if (method_name == "clear") {
          result->Success(flutter::EncodableValue(ClearWindowsMediaPlayback()));
          return;
        }
        if (method_name != "show") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_args", "Expected map arguments.");
          return;
        }
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
        result->Success(flutter::EncodableValue(
            ShowWindowsMediaPlayback(*playback)));
      });
}

bool FlutterWindow::ShowWindowsMediaPlayback(
    const flutter::EncodableMap& playback) {
  const std::string* source_device_id = FindString(playback, "sourceDeviceId");
  const std::string* playback_id = FindString(playback, "playbackId");
  if (source_device_id == nullptr || playback_id == nullptr ||
      source_device_id->empty() || playback_id->empty()) {
    return false;
  }

  try {
    try {
      winrt::init_apartment();
    } catch (...) {
    }

    if (!media_playback_player_) {
      media_playback_player_ = winrt::Windows::Media::Playback::MediaPlayer();
      media_playback_player_.CommandManager().IsEnabled(false);
    }
    auto controls = media_playback_player_.SystemMediaTransportControls();
    controls.IsEnabled(true);
    controls.IsPlayEnabled(IsTrue(playback, "canPlay"));
    controls.IsPauseEnabled(IsTrue(playback, "canPause"));
    controls.IsNextEnabled(IsTrue(playback, "canSkipNext"));
    controls.IsPreviousEnabled(IsTrue(playback, "canSkipPrevious"));

    const std::string playback_state =
        FindString(playback, "playbackState") != nullptr
            ? *FindString(playback, "playbackState")
            : "stopped";
    using winrt::Windows::Media::MediaPlaybackStatus;
    if (playback_state == "playing") {
      controls.PlaybackStatus(MediaPlaybackStatus::Playing);
    } else if (playback_state == "paused") {
      controls.PlaybackStatus(MediaPlaybackStatus::Paused);
    } else if (playback_state == "buffering") {
      controls.PlaybackStatus(MediaPlaybackStatus::Changing);
    } else {
      controls.PlaybackStatus(MediaPlaybackStatus::Stopped);
    }

    const bool can_seek = IsTrue(playback, "canSeek");

    auto display_updater = controls.DisplayUpdater();
    display_updater.ClearAll();
    display_updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
    const std::string* app_name = FindString(playback, "appName");
    const std::string* title = FindString(playback, "title");
    const std::string* artist = FindString(playback, "artist");
    const std::string* album = FindString(playback, "album");
    display_updater.AppMediaId(Utf16FromUtf8(
        app_name != nullptr && !app_name->empty() ? *app_name : "Rift"));
    auto music_properties = display_updater.MusicProperties();
    music_properties.Title(Utf16FromUtf8(
        title != nullptr && !title->empty()
            ? *title
            : (app_name != nullptr && !app_name->empty() ? *app_name
                                                          : "Remote playback")));
    music_properties.Artist(Utf16FromUtf8(
        artist != nullptr ? *artist : std::string()));
    music_properties.AlbumTitle(Utf16FromUtf8(
        album != nullptr ? *album : std::string()));
    auto artwork = CreateArtworkReference(playback);
    if (artwork) {
      display_updater.Thumbnail(artwork);
    }
    display_updater.Update();

    winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties
        timeline_properties;
    if (can_seek) {
      timeline_properties.StartTime(std::chrono::milliseconds(0));
      const int64_t position_ms = FindInt64(playback, "positionMs").value_or(0);
      timeline_properties.Position(std::chrono::milliseconds(position_ms));
      const auto duration_ms = FindInt64(playback, "durationMs");
      if (duration_ms.has_value() && duration_ms.value() > 0) {
        timeline_properties.MinSeekTime(std::chrono::milliseconds(0));
        timeline_properties.MaxSeekTime(
            std::chrono::milliseconds(duration_ms.value()));
        timeline_properties.EndTime(std::chrono::milliseconds(duration_ms.value()));
      }
    }
    controls.UpdateTimelineProperties(timeline_properties);

    std::lock_guard<std::mutex> callback_lock(media_playback_callback_mutex_);
    if (media_playback_button_pressed_token_.value != 0) {
      controls.ButtonPressed(media_playback_button_pressed_token_);
      media_playback_button_pressed_token_ = {};
    }
    if (media_playback_position_change_token_.value != 0) {
      controls.PlaybackPositionChangeRequested(
          media_playback_position_change_token_);
      media_playback_position_change_token_ = {};
    }

    media_playback_button_pressed_token_ = controls.ButtonPressed(
        [this, source_device_id_value = *source_device_id,
         playback_id_value = *playback_id](auto&&, auto&& args) {
          std::lock_guard<std::mutex> lock(media_playback_callback_mutex_);
          using winrt::Windows::Media::SystemMediaTransportControlsButton;
          std::optional<std::string> action;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play:
              action = "play";
              break;
            case SystemMediaTransportControlsButton::Pause:
              action = "pause";
              break;
            case SystemMediaTransportControlsButton::Next:
              action = "next";
              break;
            case SystemMediaTransportControlsButton::Previous:
              action = "previous";
              break;
            default:
              break;
          }
          if (action.has_value()) {
            PostWindowsMediaPlaybackAction(source_device_id_value,
                                           playback_id_value, action.value());
          }
        });
    if (can_seek) {
      media_playback_position_change_token_ =
          controls.PlaybackPositionChangeRequested(
              [this, source_device_id_value = *source_device_id,
               playback_id_value = *playback_id](auto&&, auto&& args) {
                std::lock_guard<std::mutex> lock(media_playback_callback_mutex_);
                const auto position_ms = static_cast<int64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        args.RequestedPlaybackPosition())
                        .count());
                PostWindowsMediaPlaybackAction(source_device_id_value,
                                               playback_id_value, "seek",
                                               position_ms);
              });
    }
    return true;
  } catch (...) {
    return false;
  }
}

bool FlutterWindow::ClearWindowsMediaPlayback() {
  try {
    if (!media_playback_player_) {
      return true;
    }
    auto controls = media_playback_player_.SystemMediaTransportControls();
    std::lock_guard<std::mutex> callback_lock(media_playback_callback_mutex_);
    controls.IsEnabled(false);
    controls.IsPlayEnabled(false);
    controls.IsPauseEnabled(false);
    controls.IsNextEnabled(false);
    controls.IsPreviousEnabled(false);
    if (media_playback_button_pressed_token_.value != 0) {
      controls.ButtonPressed(media_playback_button_pressed_token_);
      media_playback_button_pressed_token_ = {};
    }
    if (media_playback_position_change_token_.value != 0) {
      controls.PlaybackPositionChangeRequested(
          media_playback_position_change_token_);
      media_playback_position_change_token_ = {};
    }
    controls.PlaybackStatus(
        winrt::Windows::Media::MediaPlaybackStatus::Closed);
    auto display_updater = controls.DisplayUpdater();
    display_updater.ClearAll();
    display_updater.Update();
    controls.UpdateTimelineProperties(
        winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties());
    media_playback_player_.Close();
    media_playback_player_ = nullptr;
  } catch (...) {
  }

  return true;
}

void FlutterWindow::PostWindowsMediaPlaybackAction(
    const std::string& source_device_id,
    const std::string& playback_id,
    const std::string& action,
    std::optional<int64_t> position_ms) {
  if (source_device_id.empty() || playback_id.empty() || action.empty() ||
      GetHandle() == nullptr) {
    return;
  }

  auto posted_action = std::make_unique<PostedMediaPlaybackAction>();
  posted_action->payload = {
      {flutter::EncodableValue("sourceDeviceId"),
       flutter::EncodableValue(source_device_id)},
      {flutter::EncodableValue("playbackId"),
       flutter::EncodableValue(playback_id)},
      {flutter::EncodableValue("action"), flutter::EncodableValue(action)}};
  if (position_ms.has_value()) {
    posted_action->payload[flutter::EncodableValue("positionMs")] =
        flutter::EncodableValue(position_ms.value());
  }

  auto* raw_posted_action = posted_action.release();
  if (!PostMessageW(GetHandle(), kRiftMediaPlaybackActionMessage,
                    reinterpret_cast<WPARAM>(raw_posted_action), 0)) {
    delete raw_posted_action;
  }
}

void FlutterWindow::DispatchPostedWindowsMediaPlaybackAction(WPARAM wparam) {
  std::unique_ptr<PostedMediaPlaybackAction> posted_action(
      reinterpret_cast<PostedMediaPlaybackAction*>(wparam));
  if (!windows_media_playback_method_channel_ || posted_action == nullptr) {
    return;
  }

  windows_media_playback_method_channel_->InvokeMethod(
      "mediaPlaybackAction",
      std::make_unique<flutter::EncodableValue>(std::move(posted_action->payload)));
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
  icon_data.uFlags = NIF_MESSAGE;
  icon_data.uCallbackMessage = kRiftShellNotifyMessage;
  shell_notification_icon_registered_ =
      Shell_NotifyIconW(NIM_MODIFY, &icon_data) == TRUE;
}

void FlutterWindow::CleanupShellNotificationIcon() {
  if (!shell_notification_icon_registered_ || GetHandle() == nullptr) {
    return;
  }

  NOTIFYICONDATAW icon_data = {};
  icon_data.cbSize = sizeof(icon_data);
  icon_data.hWnd = GetHandle();
  icon_data.uID = kRiftShellNotifyId;
  icon_data.uFlags = NIF_MESSAGE;
  icon_data.uCallbackMessage = kTrayManagerNotifyMessage;
  Shell_NotifyIconW(NIM_MODIFY, &icon_data);
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
  const bool shown = Shell_NotifyIconW(NIM_MODIFY, &icon_data) == TRUE;
  if (!shown) {
    CleanupShellNotificationIcon();
  }
  return shown;
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
