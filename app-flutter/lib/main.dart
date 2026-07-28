import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'constants.dart';
import 'src/pairing/device_pairing_coordinator.dart';
import 'src/clipboard/clipboard_sync_coordinator.dart';
import 'src/notification/notification_sync_coordinator.dart';
import 'src/file_transfer/file_transfer_coordinator.dart';
import 'src/ui/app_shell.dart';
import 'screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/ipc/json_rpc_client.dart';
import 'src/ipc/transport_factory.dart';
import 'src/notification_sync_policy.dart';
import 'src/clipboard/desktop_clipboard_manager.dart';
import 'src/file_transfer/send_queue_controller.dart';
import 'src/ui/local_events_notifier.dart';
import 'src/platform/android_shell.dart';
import 'src/media_playback/android_remote_media_playback_coordinator.dart';
import 'src/platform/linux_notifications.dart';
import 'src/platform/macos_notifications.dart';
import 'src/platform/notification_route.dart';
import 'src/platform/windows_shell.dart';

const _desktopClipboardChannel = MethodChannel('rift/desktop/clipboard');
String? _lastDesktopClipboardReadFingerprint;

String _desktopClipboardFingerprint(String contentType, Uint8List bytes) {
  final byteDigest = base64Encode(bytes);
  return '$contentType:${bytes.length}:$byteDigest';
}

Future<ClipboardContentPayload?> _readDesktopClipboardContent() async {
  final raw = await _desktopClipboardChannel.invokeMethod<Object>(
    'getClipboardContent',
  );
  if (raw is! Map) {
    if (_lastDesktopClipboardReadFingerprint != 'empty') {
      _lastDesktopClipboardReadFingerprint = 'empty';
      debugPrint(
          '[Desktop Clipboard] No clipboard payload returned by native bridge.');
    }
    return null;
  }

  final contentType = raw['contentType'] as String?;
  final bytes = raw['bytes'];
  if (contentType == null || bytes is! Uint8List) {
    debugPrint(
      '[Desktop Clipboard] Native bridge returned an incomplete payload: '
      'contentType=$contentType bytesType=${bytes.runtimeType}',
    );
    return null;
  }

  final fingerprint = _desktopClipboardFingerprint(contentType, bytes);
  if (_lastDesktopClipboardReadFingerprint != fingerprint) {
    _lastDesktopClipboardReadFingerprint = fingerprint;
    debugPrint(
      '[Desktop Clipboard] Read native payload type=$contentType bytes=${bytes.length}',
    );
  }

  return ClipboardContentPayload(
    contentType: contentType,
    bytes: bytes,
  );
}

Future<void> _writeDesktopClipboardContent(
  ClipboardContentPayload payload,
) async {
  final applied = await _desktopClipboardChannel.invokeMethod<bool>(
    'setClipboardContent',
    {
      'contentType': payload.contentType,
      'bytes': payload.bytes,
    },
  );
  if (applied != true) {
    throw StateError(
      'Desktop clipboard payload was not applied for ${payload.contentType}.',
    );
  }
  debugPrint(
    '[Desktop Clipboard] Applied native payload type=${payload.contentType} bytes=${payload.byteSize}',
  );
}

DesktopClipboardManager _createDesktopClipboardManager(
    JsonRpcRiftClient client) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return DesktopClipboardManager(
      client,
      readClipboardContent: _readDesktopClipboardContent,
      writeClipboardContent: _writeDesktopClipboardContent,
      supportedContentTypes: const <String>{'text/plain', 'image/png'},
    );
  }

  return DesktopClipboardManager(client);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(800, 600),
      center: true,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      // override close button
      await windowManager.setPreventClose(true);
    });
  }

  final client = JsonRpcRiftClient(TransportFactory.create());
  final clipboardManager = _createDesktopClipboardManager(client);
  // Start the connection immediately in the background
  client.connect().catchError((Object error, StackTrace stackTrace) {
    debugPrint('Initial IPC connection failed (will auto-reconnect): $error');
  });
  clipboardManager.start().catchError((Object error, StackTrace stackTrace) {
    debugPrint('Windows clipboard manager failed to start: $error');
  });

  final prefs = await SharedPreferences.getInstance();
  final hasCompletedOnboarding =
      prefs.getBool('has_completed_onboarding') ?? false;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DesktopClipboardManager?>.value(
            value: clipboardManager),
        Provider<JsonRpcRiftClient>.value(value: client),
        ChangeNotifierProvider<SendQueueController>(
          create: (context) => SendQueueController(
            context.read<JsonRpcRiftClient>(),
          ),
        ),
        ChangeNotifierProvider<LocalEventsNotifier>(
          create: (context) =>
              LocalEventsNotifier(context.read<JsonRpcRiftClient>()),
        ),
      ],
      child: RiftApp(hasCompletedOnboarding: hasCompletedOnboarding),
    ),
  );
}

class RiftApp extends StatefulWidget {
  final bool hasCompletedOnboarding;
  const RiftApp({super.key, this.hasCompletedOnboarding = false});

  @override
  State<RiftApp> createState() => _RiftAppState();
}

class _RiftAppState extends State<RiftApp> with TrayListener, WindowListener {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<AppShellState> _appShellKey = GlobalKey<AppShellState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<bool>? _connectionChangedSub;
  DevicePairingCoordinator? _devicePairingCoordinator;
  ClipboardSyncCoordinator? _clipboardSyncCoordinator;
  NotificationSyncCoordinator? _notificationSyncCoordinator;
  FileTransferCoordinator? _fileTransferCoordinator;
  DesktopClipboardManager? _clipboardManager;
  final ValueNotifier<String?> _historyRouteNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<String?> _sharedClipboardTextNotifier =
      ValueNotifier<String?>(null);
  AndroidRemoteMediaPlaybackCoordinator? _androidRemoteMediaPlayback;

  bool get _enableDesktopShellIntegration =>
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    if (_enableDesktopShellIntegration) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      _initSystemTray();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final client = context.read<JsonRpcRiftClient>();
      _devicePairingCoordinator = DevicePairingCoordinator(
        client: client,
        navigatorKey: _navigatorKey,
        appShellKey: _appShellKey,
        onNotify: _maybeNotify,
        onNotifyWithRoute: _maybeNotifyWithRoute,
      )..init();
      _clipboardSyncCoordinator = ClipboardSyncCoordinator(
        client: client,
        onNotifyWithRoute: _maybeNotifyWithRoute,
      )
        ..init()
        ..bindIpcEvents();
      _notificationSyncCoordinator = NotificationSyncCoordinator(
        client: client,
      )..init();
      _fileTransferCoordinator = FileTransferCoordinator(
        client: client,
        navigatorKey: _navigatorKey,
        appShellKey: _appShellKey,
        scaffoldMessengerKey: _scaffoldMessengerKey,
        onNotify: _maybeNotify,
        onNotifyWithRoute: _maybeNotifyWithRoute,
      )..init();
      unawaited(context.read<SendQueueController>().ensureRestored());
      _bindPlatformNotificationActions();
      _bindMediaPlayback();
      _bindNotifications();
      _bindConnectionRecovery();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clipboardManager ??= context.read<DesktopClipboardManager?>();
  }

  Future<void> _bindPlatformNotificationActions() async {
    WindowsShell.setMethodCallHandler(_handlePlatformNotificationMethodCall);
    LinuxNotifications.setMethodCallHandler(
      _handlePlatformNotificationMethodCall,
    );
    MacOSNotifications.setMethodCallHandler(
      _handlePlatformNotificationMethodCall,
    );
    AndroidShell.setMethodCallHandler(_handlePlatformNotificationMethodCall);

    if (Platform.isAndroid) {
      final pendingAction = await AndroidShell.consumeLaunchAction();
      if (pendingAction != null) {
        _handleNotificationActionPayload(
          Map<String, dynamic>.from(pendingAction),
        );
      }
    }

    if (MacOSNotifications.supportsPendingShareHandoff) {
      final pendingSharePayload =
          await MacOSNotifications.consumePendingShareItems();
      if (pendingSharePayload != null) {
        _handleNotificationActionPayload(pendingSharePayload);
      }
    }
  }

  void _bindConnectionRecovery() {
    final client = context.read<JsonRpcRiftClient>();
    _connectionChangedSub?.cancel();
    _connectionChangedSub = client.onConnectionChanged.listen((isConnected) {
      if (isConnected) {
        unawaited(
            _clipboardSyncCoordinator?.flushPendingExternalClipboardPayloads());
        unawaited(
            _notificationSyncCoordinator?.flushPendingNotificationSyncEvents());
        unawaited(_notificationSyncCoordinator
            ?.flushPendingDesktopNotificationActions());
        unawaited(_fileTransferCoordinator?.flushPendingSharedSendItems());
        unawaited(_reapplyNotificationSyncPolicy(client));
      }
    });
  }

  Future<void> _reapplyNotificationSyncPolicy(JsonRpcRiftClient client) async {
    try {
      await pushSavedNotificationSyncPolicy(client);
    } catch (error) {
      if (JsonRpcRiftClient.isMethodNotFoundError(error)) {
        return;
      }
      debugPrint(
        '[Notification Sync] Failed to reapply saved policy after reconnect: $error',
      );
    }
  }

  Future<dynamic> _handlePlatformNotificationMethodCall(MethodCall call) async {
    final mediaPlaybackResult =
        await _androidRemoteMediaPlayback?.handlePlatformMethodCall(call);
    if (mediaPlaybackResult != null) {
      return mediaPlaybackResult;
    }

    if (call.method == 'notificationActivated') {
      final arguments = call.arguments;
      if (arguments is Map) {
        _handleNotificationActionPayload(Map<String, dynamic>.from(arguments));
      }
      return null;
    }

    if (call.method == 'notificationSyncEvent') {
      final arguments = call.arguments;
      if (arguments is Map) {
        await _notificationSyncCoordinator?.submitNativeNotificationSyncEvent(
          Map<String, dynamic>.from(arguments),
        );
      }
    }
    return null;
  }

  void _bindMediaPlayback() {
    final client = context.read<JsonRpcRiftClient>();
    if (Platform.isAndroid) {
      _androidRemoteMediaPlayback =
          AndroidRemoteMediaPlaybackCoordinator(client);
      unawaited(_androidRemoteMediaPlayback!.start());
    }
  }

  void _handleNotificationActionPayload(Map<String, dynamic> payload) {
    final route = payload['route']?.toString();
    final notificationAction = payload['notificationAction']?.toString();
    final notificationId = payload['notificationId']?.toString();
    if (notificationAction != null &&
        notificationId != null &&
        notificationId.isNotEmpty) {
      unawaited(
        _notificationSyncCoordinator?.submitDesktopNotificationAction(
          notificationId: notificationId,
          action: notificationAction,
        ),
      );
    }
    if (route == null || route.isEmpty) {
      return;
    }

    switch (route) {
      case NotificationRoute.devices:
        _appShellKey.currentState?.showRoute(route);
        return;
      case NotificationRoute.clipboardSend:
        unawaited(
            _clipboardSyncCoordinator?.submitExternalClipboardPayload(payload));
        return;
      case NotificationRoute.historySend:
        if (payload['items'] is List) {
          unawaited(_fileTransferCoordinator?.flushPendingSharedSendItems());
        }
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
      case NotificationRoute.historyClipboard:
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
      case NotificationRoute.historyNotifications:
        _appShellKey.currentState?.showNotificationsRoute();
        return;
      case NotificationRoute.pairing:
        _devicePairingCoordinator?.openIncomingPairingRequest(payload);
        return;
      case NotificationRoute.historyIncomingOffers:
      case NotificationRoute.historyTransferActivity:
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
    }
  }

  Future<void> _initSystemTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'app_icon.ico' : 'app_icon.png',
      );
    } catch (e) {
      debugPrint('Failed to load tray icon: $e');
    }
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

  @override
  void dispose() {
    if (_enableDesktopShellIntegration) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    _devicePairingCoordinator?.dispose();
    _clipboardSyncCoordinator?.dispose();
    _notificationSyncCoordinator?.dispose();
    _fileTransferCoordinator?.dispose();
    _connectionChangedSub?.cancel();
    unawaited(_androidRemoteMediaPlayback?.dispose());
    unawaited(_clipboardManager?.dispose());
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() {
    if (!_enableDesktopShellIntegration) return;
    unawaited(_clipboardManager?.setWindowVisible(true));
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!_enableDesktopShellIntegration) return;
    if (menuItem.key == 'show_window') {
      unawaited(_clipboardManager?.setWindowVisible(true));
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      windowManager.destroy();
    }
  }

  void _maybeNotify(String title, String body) {
    _maybeNotifyWithRoute(title: title, body: body);
  }

  void _maybeNotifyWithRoute({
    required String title,
    required String body,
    String? route,
    String? destinationPath,
    Map<String, Object?>? payload,
  }) {
    unawaited(() async {
      try {
        if (Platform.isAndroid && route != null) {
          await AndroidShell.showNotification(
            title: title,
            body: body,
            route: route,
            destinationPath: destinationPath,
            payload: payload,
          );
          return;
        }
        if (Platform.isWindows && route != null) {
          await WindowsShell.showNotification(
            title: title,
            body: body,
            route: route,
            destinationPath: destinationPath,
            payload: payload,
          );
          return;
        }
        if (Platform.isLinux && route != null) {
          await LinuxNotifications.show(
            title: title,
            body: body,
            route: route,
            destinationPath: destinationPath,
            payload: payload,
          );
          return;
        }
        if (Platform.isMacOS) {
          await MacOSNotifications.show(
            title: title,
            body: body,
            route: route,
            payload: payload,
          );
        }
      } catch (_) {
        // Best-effort: depends on user permission and runner support.
      }
    }());
  }

  @override
  void onWindowClose() async {
    if (!_enableDesktopShellIntegration) return;
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await _clipboardManager?.setWindowVisible(false);
      windowManager.hide();
    }
  }

  void _bindNotifications() {}

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: AppStrings.appTitle,
      theme: _buildRiftTheme(),
      home: widget.hasCompletedOnboarding
          ? AppShell(
              key: _appShellKey,
              historyRouteNotifier: _historyRouteNotifier,
              sharedClipboardTextNotifier: _sharedClipboardTextNotifier,
            )
          : const OnboardingScreen(),
    );
  }
}

ThemeData _buildRiftTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00327d),
    onPrimary: Color(0xFFffffff),
    primaryContainer: Color(0xFF0047ab),
    onPrimaryContainer: Color(0xFFa5bdff),
    secondary: Color(0xFF545f73),
    onSecondary: Color(0xFFffffff),
    secondaryContainer: Color(0xFFd5e0f8),
    onSecondaryContainer: Color(0xFF586377),
    tertiary: Color(0xFF1a12af),
    onTertiary: Color(0xFFffffff),
    tertiaryContainer: Color(0xFF3636c5),
    onTertiaryContainer: Color(0xFFb7b8ff),
    error: Color(0xFFba1a1a),
    onError: Color(0xFFffffff),
    errorContainer: Color(0xFFffdad6),
    onErrorContainer: Color(0xFF93000a),
    surface: Color(0xFFf8f9ff),
    onSurface: Color(0xFF0b1c30),
    surfaceContainerHighest: Color(0xFFd3e4fe),
    onSurfaceVariant: Color(0xFF434653),
    outline: Color(0xFF737784),
    outlineVariant: Color(0xFFc3c6d5),
  );

  final inter = GoogleFonts.interTextTheme();

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    textTheme: inter.copyWith(
      headlineLarge: inter.headlineLarge?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.01,
          height: 40 / 32),
      headlineMedium: inter.headlineMedium?.copyWith(
          fontSize: 24, fontWeight: FontWeight.w600, height: 32 / 24),
      bodyLarge: inter.bodyLarge?.copyWith(
          fontSize: 18, fontWeight: FontWeight.w400, height: 28 / 18),
      bodyMedium: inter.bodyMedium?.copyWith(
          fontSize: 16, fontWeight: FontWeight.w400, height: 24 / 16),
      bodySmall: inter.bodySmall?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w400, height: 20 / 14),
      labelMedium: inter.labelMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.05,
          height: 16 / 14),
      labelSmall: inter.labelSmall?.copyWith(
          fontSize: 12, fontWeight: FontWeight.w500, height: 16 / 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      titleTextStyle: inter.headlineMedium?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      filled: true,
      fillColor: colorScheme.surface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        side: BorderSide(color: colorScheme.primary, width: 1),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return inter.labelSmall!.copyWith(
              color: colorScheme.onSurface, fontWeight: FontWeight.w600);
        }
        return inter.labelSmall!.copyWith(color: colorScheme.onSurfaceVariant);
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: colorScheme.onPrimaryContainer);
        }
        return IconThemeData(color: colorScheme.onSurfaceVariant);
      }),
    ),
  );
}
