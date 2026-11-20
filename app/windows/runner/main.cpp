#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

#ifndef _DEBUG
  // One copy at a time: two would share (and corrupt) the encryption state.
  // A second launch brings the running copy (perhaps hidden in the tray) to
  // the front instead. Debug builds may run side by side with an installed copy.
  ::CreateMutexW(nullptr, TRUE, L"nullpointr.Hanashi.instance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_SHOW);
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }
#endif

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Started at login: the window waits in the tray.
  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--hidden") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Hanashi", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
