#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr const wchar_t kRiftWindowClassName[] =
    L"RIFT_FLUTTER_RUNNER_WIN32_WINDOW";
constexpr ULONG_PTR kRiftSendFilesCopyDataId = 0x52465446;  // 'RFTF'

// Splits raw command-line arguments into launch flags and openable file paths.
void PartitionArguments(std::vector<std::wstring>* file_paths,
                        std::vector<std::string>* dart_arguments) {
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return;
  }

  for (int i = 1; i < argc; i++) {
    const std::wstring argument(argv[i]);
    if (!argument.empty() && argument[0] == L'-') {
      dart_arguments->push_back(Utf8FromUtf16(argv[i]));
      continue;
    }

    DWORD attributes = ::GetFileAttributesW(argument.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      file_paths->push_back(argument);
    } else {
      dart_arguments->push_back(Utf8FromUtf16(argv[i]));
    }
  }

  ::LocalFree(argv);
}

// Forwards opened files to an already-running instance. Returns true when an
// existing instance accepted the handoff and this process should exit.
bool ForwardFilesToRunningInstance(const std::vector<std::wstring>& file_paths) {
  if (file_paths.empty()) {
    return false;
  }

  HWND existing = ::FindWindowW(kRiftWindowClassName, nullptr);
  if (existing == nullptr) {
    return false;
  }

  std::wstring paths;
  for (const auto& path : file_paths) {
    paths.append(path);
    paths.push_back(L'\0');
  }
  paths.push_back(L'\0');

  COPYDATASTRUCT copy_data = {};
  copy_data.dwData = kRiftSendFilesCopyDataId;
  copy_data.cbData = static_cast<DWORD>(paths.size() * sizeof(wchar_t));
  copy_data.lpData = paths.data();

  ::AllowSetForegroundWindow(ASFW_ANY);
  DWORD_PTR result = FALSE;
  return ::SendMessageTimeoutW(
             existing, WM_COPYDATA, 0,
             reinterpret_cast<LPARAM>(&copy_data),
             SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000, &result) != 0 &&
         result == TRUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::wstring> opened_files;
  std::vector<std::string> command_line_arguments;
  PartitionArguments(&opened_files, &command_line_arguments);

  // "Open With Rift" while the app is already running hands the files to the
  // existing instance instead of starting a second one.
  if (ForwardFilesToRunningInstance(opened_files)) {
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Rift", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (!opened_files.empty()) {
    window.QueueSendFiles(opened_files);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
