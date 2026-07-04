import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'constants.dart';
import 'screens/event_log_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/trusted_devices_screen.dart';
import 'screens/clipboard_debug_screen.dart';
import 'screens/settings_screen.dart';

import 'src/ipc/json_rpc_client.dart';
import 'src/ipc/transport_factory.dart';
import 'src/clipboard/desktop_clipboard_manager.dart';

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
  final clipboardManager = DesktopClipboardManager(client);
  // Start the connection immediately in the background
  client.connect().catchError((Object error, StackTrace stackTrace) {
    debugPrint('Initial IPC connection failed (will auto-reconnect): $error');
  });
  clipboardManager.start().catchError((Object error, StackTrace stackTrace) {
    debugPrint('Windows clipboard manager failed to start: $error');
  });

  runApp(
    Provider<DesktopClipboardManager?>.value(
      value: clipboardManager,
      child: Provider<JsonRpcRiftClient>.value(
        value: client,
        child: const RiftApp(),
      ),
    ),
  );
}

class RiftApp extends StatefulWidget {
  const RiftApp({super.key});

  @override
  State<RiftApp> createState() => _RiftAppState();
}

class _RiftAppState extends State<RiftApp> with TrayListener, WindowListener {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<String>? _clipboardStatusSub;
  String? _activePairingDeviceId;
  bool _clipboardServiceStarted = false;
  DesktopClipboardManager? _clipboardManager;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initSystemTray();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindPairingRequests();
      _bindClipboardChannel();
      _bindDesktopClipboardStatus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clipboardManager ??= context.read<DesktopClipboardManager?>();
  }

  void _bindDesktopClipboardStatus() {
    final clipboardManager = _clipboardManager;
    if (clipboardManager == null) return;
    
    _clipboardStatusSub = clipboardManager.onStatusUpdate.listen((status) {
      if (!mounted) return;
      _scaffoldMessengerKey.currentState?.clearSnackBars();
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(status),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  static const _clipboardChannel = MethodChannel('com.biennvops.rift/clipboard');

  Future<void> _bindClipboardChannel() async {
    // The native clipboard channel only exists on Android.
    if (!Platform.isAndroid) return;
    final client = context.read<JsonRpcRiftClient>();
    final clipboardManager = _clipboardManager;
    try {
      await _clipboardChannel.invokeMethod('startService');
      _clipboardServiceStarted = true;
    } catch (e) {
      debugPrint('Failed to start clipboard service: $e');
    }
    _clipboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onClipboardChanged') {
        final text = call.arguments['text'] as String?;
        if (text != null) {
          final bytes = utf8.encode(text);
          final hash = sha256.convert(bytes).toString();
          final contentBase64 = base64.encode(bytes);
          try {
             await client.notifyClipboardChange(
               contentType: 'text/plain',
               byteSize: bytes.length,
               sha256: hash,
               contentBase64: contentBase64,
             );
             clipboardManager?.notifyStatus('Clipboard sent to peers');
          } catch (e) {
             debugPrint('Failed to notify daemon: $e');
          }
        }
      }
    });
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
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _pairingRequestSub?.cancel();
    _clipboardStatusSub?.cancel();
    unawaited(_clipboardManager?.dispose());
    if (Platform.isAndroid && _clipboardServiceStarted) {
      unawaited(
        _clipboardChannel.invokeMethod('stopService').catchError((Object error) {
          debugPrint('Failed to stop clipboard service: $error');
        }),
      );
    }
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_clipboardManager?.setWindowVisible(true));
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      unawaited(_clipboardManager?.setWindowVisible(true));
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
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
      // Guard against notification bursts stacking multiple pairing screens.
      if (_activePairingDeviceId != null) return;

      _activePairingDeviceId = deviceId;
      try {
        navigator
            .push(
              MaterialPageRoute<void>(
                builder: (_) => PairingScreen(
                  initialDeviceId: deviceId,
                  initialDisplayName: event['displayName']?.toString(),
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: AppStrings.appTitle,
      theme: ThemeData(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _statusPollTimer;
  bool _isConnected = false;
  int _trustedCount = 0;
  int _onlineTrustedCount = 0;
  int _discoveredCount = 0;
  bool _isDiscovering = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncHomeStatus();
      _statusPollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _syncHomeStatus(),
      );
    });
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncHomeStatus() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();
    final nextConnected = client.isConnected;

    if (!nextConnected) {
      if (_isConnected ||
          _trustedCount != 0 ||
          _onlineTrustedCount != 0 ||
          _discoveredCount != 0 ||
          _isDiscovering) {
        setState(() {
          _isConnected = false;
          _trustedCount = 0;
          _onlineTrustedCount = 0;
          _discoveredCount = 0;
          _isDiscovering = false;
        });
      }
      return;
    }

    try {
      final trustedResult = await client.listTrustedPeers() as Map;
      final discoveredResult = await client.listDiscoveredPeers() as Map;
      if (!mounted) return;

      final trustedPeers = List<dynamic>.from(trustedResult['peers'] ?? const []);
      final discoveredPeers = List<dynamic>.from(
        discoveredResult['peers'] ?? const [],
      );
      final onlineTrusted = trustedPeers.where((peer) {
        return peer is Map && peer['presence']?.toString() == 'online';
      }).length;
      final isDiscovering = discoveredResult['isDiscovering'] == true;

      if (nextConnected == _isConnected &&
          trustedPeers.length == _trustedCount &&
          onlineTrusted == _onlineTrustedCount &&
          discoveredPeers.length == _discoveredCount &&
          isDiscovering == _isDiscovering) {
        return;
      }

      setState(() {
        _isConnected = nextConnected;
        _trustedCount = trustedPeers.length;
        _onlineTrustedCount = onlineTrusted;
        _discoveredCount = discoveredPeers.length;
        _isDiscovering = isDiscovering;
      });
    } catch (_) {
      if (!_isConnected) return;
      setState(() {
        _isConnected = false;
        _trustedCount = 0;
        _onlineTrustedCount = 0;
        _discoveredCount = 0;
        _isDiscovering = false;
      });
    }
  }

  String _buildDaemonSubtitle() {
    if (!_isConnected) {
      return 'Waiting for the local daemon.';
    }

    final parts = <String>[
      '$_trustedCount trusted',
      '$_onlineTrustedCount online',
      '$_discoveredCount discovered',
      _isDiscovering ? 'discovery running' : 'discovery idle',
    ];
    return parts.join('  •  ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.appTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppStrings.homeSubtitle),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: _isConnected
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(
                  _isConnected ? Icons.link : Icons.link_off,
                  color: _isConnected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  _isConnected
                      ? AppStrings.daemonConnected
                      : AppStrings.daemonReconnecting,
                ),
                subtitle: Text(
                  _isConnected
                      ? _buildDaemonSubtitle()
                      : 'Waiting for the local daemon.',
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ClipboardDebugScreen(),
                  ),
                );
              },
              child: const Text('Open Clipboard Debug'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TrustedDevicesScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openTrustedDevices),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EventLogScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openEventLog),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openSettings),
            ),
          ],
        ),
      ),
    );
  }
}
