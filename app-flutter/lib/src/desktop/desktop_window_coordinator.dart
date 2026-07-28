import 'dart:async';
import 'dart:io';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../clipboard/desktop_clipboard_manager.dart';

class DesktopWindowCoordinator with TrayListener, WindowListener {
  final DesktopClipboardManager? clipboardManager;
  final bool enableDesktopShellIntegration;

  DesktopWindowCoordinator({
    this.clipboardManager,
    required this.enableDesktopShellIntegration,
  });

  void init() {
    if (enableDesktopShellIntegration) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      _initSystemTray();
    }
  }

  Future<void> _initSystemTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
    );
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: 'Show Rift',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: 'Exit',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  void dispose() {
    if (enableDesktopShellIntegration) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (!enableDesktopShellIntegration) return;
    unawaited(clipboardManager?.setWindowVisible(true));
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!enableDesktopShellIntegration) return;
    if (menuItem.key == 'show_window') {
      unawaited(clipboardManager?.setWindowVisible(true));
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    if (!enableDesktopShellIntegration) return;
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await clipboardManager?.setWindowVisible(false);
      windowManager.hide();
    }
  }
}
