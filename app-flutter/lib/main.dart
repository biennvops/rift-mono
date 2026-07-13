import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'constants.dart';
import 'package:app_flutter/screens/security_dashboard_screen.dart';
import 'package:app_flutter/screens/operations_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/trusted_devices_screen.dart';
import 'screens/clipboard_transfer_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/ipc/json_rpc_client.dart';
import 'src/ipc/transport_factory.dart';
import 'src/clipboard/desktop_clipboard_manager.dart';
import 'src/platform/macos_notifications.dart';

const _desktopClipboardChannel = MethodChannel('rift/desktop/clipboard');
String? _lastDesktopClipboardReadFingerprint;

String _desktopClipboardFingerprint(String contentType, Uint8List bytes) {
  final byteDigest = base64Encode(bytes);
  return '$contentType:${bytes.length}:$byteDigest';
}

String sanitizeIncomingFileName(String fileName) {
  final segments = fileName
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  final basename = segments.isEmpty ? null : segments.last;
  final cleaned =
      (basename ?? fileName).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  if (cleaned.isEmpty || RegExp(r'^\.+$').hasMatch(cleaned)) {
    return 'incoming.bin';
  }
  return cleaned;
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
    Provider<DesktopClipboardManager?>.value(
      value: clipboardManager,
      child: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: RiftApp(hasCompletedOnboarding: hasCompletedOnboarding),
      ),
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
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  String? _activePairingDeviceId;
  bool _clipboardServiceStarted = false;
  DesktopClipboardManager? _clipboardManager;
  final Set<String> _autoAcceptingTransferIds = <String>{};

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
      _bindPairingRequests();
      _bindNotifications();
      _bindClipboardChannel();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clipboardManager ??= context.read<DesktopClipboardManager?>();
  }

  static const _clipboardChannel =
      MethodChannel('com.biennvops.rift/clipboard');

  Future<void> _applyAndroidClipboardPayload({
    required String contentType,
    required String contentBase64,
  }) async {
    final applied = await _clipboardChannel.invokeMethod<bool>(
      'setClipboardContent',
      {
        'contentType': contentType,
        'contentBase64': contentBase64,
      },
    );
    if (applied != true) {
      throw StateError('Android clipboard payload was not applied');
    }
  }

  Future<void> _bindClipboardChannel() async {
    // The native clipboard channel only exists on Android.
    if (!Platform.isAndroid) return;

    final clipboardManager = _clipboardManager;
    _clipboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onClipboardChanged') {
        final args = Map<Object?, Object?>.from(
          call.arguments as Map<Object?, Object?>? ??
              const <Object?, Object?>{},
        );
        final contentType = args['contentType'] as String?;
        final contentBase64 = args['contentBase64'] as String?;
        final text = args['text'] as String?;
        if (contentType != null && contentBase64 != null) {
          try {
            await clipboardManager?.handleExternalClipboardContent(
              ClipboardContentPayload(
                contentType: contentType,
                bytes: base64.decode(contentBase64),
              ),
            );
            return;
          } catch (e) {
            debugPrint(
                '[Android Clipboard] Failed to handle clipboard payload: $e');
          }
        }
        if (text != null) {
          try {
            await clipboardManager?.handleExternalClipboardText(text);
          } catch (e) {
            debugPrint(
                '[Android Clipboard] Failed to handle clipboard text: $e');
          }
        }
      }
    });
    try {
      final started = await _clipboardChannel.invokeMethod('startService');
      _clipboardServiceStarted = true;
      if (started != true) {
        debugPrint('[Android Clipboard] startService returned $started');
      }
    } catch (e) {
      debugPrint('[Android Clipboard] Failed to start clipboard service: $e');
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
    _pairingRequestSub?.cancel();
    _trustChangedSub?.cancel();
    _fileOfferSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    unawaited(_clipboardManager?.dispose());
    if (Platform.isAndroid && _clipboardServiceStarted) {
      unawaited(
        _clipboardChannel
            .invokeMethod('stopService')
            .catchError((Object error) {
          debugPrint('Failed to stop clipboard service: $error');
        }),
      );
    }
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

  Future<bool> _isWindowForeground() async {
    if (!_enableDesktopShellIntegration) return true;
    try {
      final visible = await windowManager.isVisible();
      final focused = await windowManager.isFocused();
      return visible && focused;
    } catch (_) {
      return true;
    }
  }

  void _maybeNotify(String title, String body) {
    if (!Platform.isMacOS) return;
    unawaited(() async {
      final foreground = await _isWindowForeground();
      if (foreground) return;
      try {
        await MacOSNotifications.show(title: title, body: body);
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

  void _bindPairingRequests() {
    final client = context.read<JsonRpcRiftClient>();
    _pairingRequestSub = client.onPairingRequest.listen((event) {
      final navigator = _navigatorKey.currentState;
      if (!mounted || navigator == null) return;

      final deviceId = event['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return;

      final displayName = event['displayName']?.toString();
      _maybeNotify(
        'Pairing request',
        displayName == null || displayName.isEmpty
            ? 'Incoming pairing request.'
            : 'Incoming pairing request from $displayName.',
      );
      // Guard against notification bursts stacking multiple pairing screens.
      if (_activePairingDeviceId != null) return;

      _activePairingDeviceId = deviceId;
      try {
        navigator
            .push(
          MaterialPageRoute<void>(
            builder: (_) => PairingScreen(
              initialDeviceId: deviceId,
              initialDisplayName: displayName,
              initialPeerFingerprint: event['fingerprint']?.toString(),
              initialExpiresInMs: (event['expiresInMs'] as num?)?.toInt(),
              initialCanApproveLocally: true,
              initialStatus: 'Incoming pairing request',
            ),
          ),
        )
            .whenComplete(() {
          if (mounted && _activePairingDeviceId == deviceId) {
            _activePairingDeviceId = null;
          }
        });
      } catch (_) {
        if (mounted && _activePairingDeviceId == deviceId) {
          _activePairingDeviceId = null;
        }
      }
    });
  }

  void _bindNotifications() {
    final client = context.read<JsonRpcRiftClient>();

    _trustChangedSub = client.onTrustChanged.listen((event) {
      final deviceId = event['deviceId']?.toString() ?? 'unknown device';
      final newState = event['newState']?.toString();
      if (newState == null || newState.isEmpty) return;
      _maybeNotify('Trust updated', '$deviceId is now $newState.');
    });

    _clipboardOfferSub = client.onClipboardOffer.listen((event) {
      final contentType = event['contentType']?.toString() ?? '';
      final offerId = event['offerId']?.toString();

      if (offerId == null) return;

      if ((contentType == 'text/plain' ||
              contentType == 'clipboard' ||
              contentType == 'image/png') &&
          Platform.isAndroid) {
        // Clipboard auto-fetch for Android-supported clipboard payloads.
        unawaited(() async {
          try {
            final result = await client.fetchClipboardContent(offerId);
            final contentBase64 = result['contentBase64'] as String?;
            if (contentBase64 == null) {
              return;
            }

            if (contentType == 'text/plain' || contentType == 'clipboard') {
              final bytes = base64.decode(contentBase64);
              final text = utf8.decode(bytes);
              await Clipboard.setData(ClipboardData(text: text));
            } else {
              await _applyAndroidClipboardPayload(
                contentType: contentType,
                contentBase64: contentBase64,
              );
            }

            _scaffoldMessengerKey.currentState?.showSnackBar(
              const SnackBar(content: Text('Clipboard synced automatically')),
            );
          } catch (e) {
            debugPrint('Auto-fetch clipboard failed: $e');
          }
        }());
      }
    });

    _clipboardExpiredSub = client.onClipboardExpired.listen((event) {
      // Intentionally left empty to avoid noisy notifications
    });

    _fileOfferSub = client.onFileOffer.listen((event) {
      unawaited(_handleIncomingFileOffer(event));
    });

    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final peer = event['peerDeviceId']?.toString() ?? 'trusted device';
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Received $fileName from $peer')),
      );
      _maybeNotify('File received', '$fileName received from $peer.');
    });

    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final reason = event['failureReason']?.toString() ?? 'failed';
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('File transfer failed for $fileName: $reason')),
      );
      _maybeNotify('File transfer failed', '$fileName failed: $reason.');
    });
  }

  Future<void> _handleIncomingFileOffer(Map<String, dynamic> event) async {
    final transferId = event['transferId']?.toString();
    final fileName = event['fileName']?.toString();
    final sourceDeviceId =
        event['sourceDeviceId']?.toString() ?? 'trusted device';
    if (transferId == null ||
        transferId.isEmpty ||
        fileName == null ||
        fileName.isEmpty) {
      return;
    }
    if (_autoAcceptingTransferIds.contains(transferId)) {
      return;
    }

    _autoAcceptingTransferIds.add(transferId);
    final client = context.read<JsonRpcRiftClient>();
    try {
      final destinationPath = await _buildDefaultIncomingFilePath(fileName);
      if (destinationPath == null || destinationPath.isEmpty) {
        return;
      }

      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Receiving $fileName from $sourceDeviceId...')),
      );
      _maybeNotify(
          'Incoming file', 'Receiving $fileName from $sourceDeviceId.');

      await client.acceptFileOffer(
        transferId: transferId,
        destinationPath: destinationPath,
        overwrite: false,
      );
    } catch (error) {
      try {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'Automatic save to Downloads was unavailable.',
        );
      } catch (_) {
        // Best-effort reject if auto-accept setup fails.
      }
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Could not auto-save incoming file: $error'),
        ),
      );
    } finally {
      _autoAcceptingTransferIds.remove(transferId);
    }
  }

  Future<String?> _buildDefaultIncomingFilePath(String fileName) async {
    final downloadsDir = await _resolveDownloadsDirectory();
    if (downloadsDir == null) {
      return null;
    }

    await downloadsDir.create(recursive: true);
    final sanitizedFileName = _sanitizeFileName(fileName);
    var candidate = File(_joinPath(downloadsDir.path, sanitizedFileName));
    if (!candidate.existsSync()) {
      return candidate.path;
    }

    final dotIndex = sanitizedFileName.lastIndexOf('.');
    final hasExtension =
        dotIndex > 0 && dotIndex < sanitizedFileName.length - 1;
    final stem = hasExtension
        ? sanitizedFileName.substring(0, dotIndex)
        : sanitizedFileName;
    final extension = hasExtension ? sanitizedFileName.substring(dotIndex) : '';

    for (var i = 1; i <= 999; i += 1) {
      candidate = File(_joinPath(downloadsDir.path, '$stem ($i)$extension'));
      if (!candidate.existsSync()) {
        return candidate.path;
      }
    }

    return candidate.path;
  }

  Future<Directory?> _resolveDownloadsDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return downloads;
      }
    } catch (_) {
      // Fall through to platform-specific defaults.
    }

    try {
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          return Directory(
            _joinPath(external.parent.parent.parent.parent.path, 'Download'),
          );
        }
      }
    } catch (_) {
      // Fall through to final fallback.
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory(_joinPath(docs.path, 'Downloads'));
    } catch (_) {
      return null;
    }
  }

  String _sanitizeFileName(String fileName) {
    return sanitizeIncomingFileName(fileName);
  }

  String _joinPath(String a, String b) {
    if (a.endsWith(Platform.pathSeparator)) {
      return '$a$b';
    }
    return '$a${Platform.pathSeparator}$b';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: AppStrings.appTitle,
      theme: _buildRiftTheme(),
      home: widget.hasCompletedOnboarding
          ? const AppShell()
          : const OnboardingScreen(),
    );
  }
}

ThemeData _buildRiftTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00328a),
    onPrimary: Color(0xFFffffff),
    primaryContainer: Color(0xFF0047bb),
    onPrimaryContainer: Color(0xFFafc1ff),
    secondary: Color(0xFF006e06),
    onSecondary: Color(0xFFffffff),
    secondaryContainer: Color(0xFF91f77e),
    onSecondaryContainer: Color(0xFF007306),
    tertiary: Color(0xFF701a00),
    onTertiary: Color(0xFFffffff),
    tertiaryContainer: Color(0xFF982700),
    onTertiaryContainer: Color(0xFFffb09a),
    error: Color(0xFFba1a1a),
    onError: Color(0xFFffffff),
    errorContainer: Color(0xFFffdad6),
    onErrorContainer: Color(0xFF93000a),
    surface: Color(0xFFfdf8f6),
    onSurface: Color(0xFF1c1b1a),
    surfaceContainerHighest: Color(0xFFe6e2df),
    onSurfaceVariant: Color(0xFF434653),
    outline: Color(0xFF737685),
    outlineVariant: Color(0xFFc3c6d6),
  );

  final inter = GoogleFonts.interTextTheme();
  final jetBrainsStyle = GoogleFonts.jetBrainsMono();

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    textTheme: inter.copyWith(
      headlineLarge: inter.headlineLarge?.copyWith(
          fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -0.02),
      headlineMedium: inter.headlineMedium?.copyWith(
          fontSize: 24, fontWeight: FontWeight.w600, height: 32 / 24),
      headlineSmall: inter.headlineSmall?.copyWith(
          fontSize: 20, fontWeight: FontWeight.w600, height: 28 / 20),
      bodyLarge: inter.bodyLarge?.copyWith(
          fontSize: 16, fontWeight: FontWeight.w400, height: 24 / 16),
      bodyMedium: inter.bodyMedium?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w400, height: 20 / 14),
      labelMedium: jetBrainsStyle.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.05,
          height: 16 / 13),
      labelSmall: jetBrainsStyle.copyWith(
          fontSize: 11, fontWeight: FontWeight.w400, height: 14 / 11),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return jetBrainsStyle.copyWith(
              fontSize: 11,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600);
        }
        return jetBrainsStyle.copyWith(
            fontSize: 11, color: colorScheme.onSurfaceVariant);
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: colorScheme.onSecondaryContainer);
        }
        return IconThemeData(color: colorScheme.onSurfaceVariant);
      }),
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    TrustedDevicesScreen(),
    ClipboardTransferScreen(),
    SecurityDashboardScreen(),
    OperationsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.shield, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('RIFT',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.devices),
            selectedIcon: Icon(Icons.devices),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.security),
            selectedIcon: Icon(Icons.security),
            label: 'Events',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Ops',
          ),
        ],
      ),
    );
  }
}
