import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
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
import 'src/notification_sync_policy.dart';
import 'src/clipboard/desktop_clipboard_manager.dart';
import 'src/file_transfer/file_storage.dart';
import 'src/file_transfer/send_queue_controller.dart';
import 'src/platform/android_shell.dart';
import 'src/platform/macos_send_files.dart';
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
        Provider<DesktopClipboardManager?>.value(value: clipboardManager),
        Provider<JsonRpcRiftClient>.value(value: client),
        ChangeNotifierProvider<SendQueueController>(
          create: (context) => SendQueueController(
            context.read<JsonRpcRiftClient>(),
          ),
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
  static const Duration _externalClipboardDuplicateWindow =
      Duration(seconds: 2);

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<_AppShellState> _appShellKey = GlobalKey<_AppShellState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<Map<String, dynamic>>? _pairingCompleteSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  StreamSubscription<Map<String, dynamic>>? _notificationPostedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationRemovedSub;
  StreamSubscription<bool>? _connectionChangedSub;
  String? _activePairingDeviceId;
  bool _clipboardServiceStarted = false;
  DesktopClipboardManager? _clipboardManager;
  final Set<String> _autoAcceptingTransferIds = <String>{};
  final ValueNotifier<String?> _historyRouteNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<String?> _sharedClipboardTextNotifier =
      ValueNotifier<String?>(null);
  final List<Map<String, dynamic>> _pendingExternalClipboardPayloads =
      <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _pendingNotificationSyncEvents =
      <Map<String, dynamic>>[];
  bool _isFlushingNotificationSyncEvents = false;
  final List<Map<String, String>> _pendingDesktopNotificationActions =
      <Map<String, String>>[];
  final List<Map<String, String>> _pendingSharedSendItems =
      <Map<String, String>>[];
  String? _lastExternalClipboardFingerprint;
  DateTime? _lastExternalClipboardAt;

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
      unawaited(context.read<SendQueueController>().ensureRestored());
      _bindPlatformNotificationActions();
      _bindPairingRequests();
      _bindNotifications();
      _bindClipboardChannel();
      _bindConnectionRecovery();
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

    _clipboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onClipboardChanged') {
        final args = Map<Object?, Object?>.from(
          call.arguments as Map<Object?, Object?>? ??
              const <Object?, Object?>{},
        );
        await _submitExternalClipboardPayload(
          args.map(
            (key, value) => MapEntry(
              key?.toString() ?? '',
              value,
            ),
          ),
        );
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

  Future<void> _bindPlatformNotificationActions() async {
    WindowsShell.setMethodCallHandler(_handlePlatformNotificationMethodCall);
    LinuxNotifications.setMethodCallHandler(
      _handlePlatformNotificationMethodCall,
    );
    MacOSNotifications.setMethodCallHandler(
      _handlePlatformNotificationMethodCall,
    );
    if (Platform.isMacOS) {
      MacOSSendFiles.setMethodCallHandler(_handleMacOSSendFilesMethodCall);
    }
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
        unawaited(_flushPendingExternalClipboardPayloads());
        unawaited(_flushPendingNotificationSyncEvents());
        unawaited(_flushPendingDesktopNotificationActions());
        unawaited(_flushPendingSharedSendItems());
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
        await _submitNativeNotificationSyncEvent(
          Map<String, dynamic>.from(arguments),
        );
      }
    }
    return null;
  }

  Future<dynamic> _handleMacOSSendFilesMethodCall(MethodCall call) async {
    if (call.method != MacOSSendFiles.callbackMethod) {
      return null;
    }

    final items = MacOSSendFiles.parseCallbackArguments(call.arguments);
    if (items.isEmpty) {
      return null;
    }

    unawaited(_enqueueSharedSendItems(items));
    _appShellKey.currentState?.showHistoryRoute(NotificationRoute.historySend);
    return null;
  }

  Future<bool?> _confirmIncomingFileOffer({
    required String fileName,
    required String sourceDeviceId,
    required String destinationPath,
  }) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !mounted) {
      return true;
    }

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Accept file transfer?'),
        content: Text(
          'Receive $fileName from $sourceDeviceId?\n\n'
          'Destination:\n$destinationPath',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  String? _externalClipboardFingerprint(Map<String, dynamic> payload) {
    final contentType = payload['contentType']?.toString();
    final contentBase64 = payload['contentBase64']?.toString();
    if (contentType != null &&
        contentType.isNotEmpty &&
        contentBase64 != null &&
        contentBase64.isNotEmpty) {
      return sha256
          .convert(utf8.encode('$contentType:$contentBase64'))
          .toString();
    }

    final text = payload['text']?.toString();
    if (text != null && text.isNotEmpty) {
      return sha256.convert(utf8.encode('text/plain:$text')).toString();
    }

    return null;
  }

  bool _shouldSuppressExternalClipboardPayload(Map<String, dynamic> payload) {
    final fingerprint = _externalClipboardFingerprint(payload);
    if (fingerprint == null) {
      return false;
    }

    final now = DateTime.now();
    if (_lastExternalClipboardFingerprint == fingerprint &&
        _lastExternalClipboardAt != null &&
        now.difference(_lastExternalClipboardAt!) <=
            _externalClipboardDuplicateWindow) {
      debugPrint(
        '[Android Clipboard] Suppressed duplicate external clipboard payload.',
      );
      return true;
    }

    _lastExternalClipboardFingerprint = fingerprint;
    _lastExternalClipboardAt = now;
    return false;
  }

  void _queuePendingExternalClipboardPayload(Map<String, dynamic> payload) {
    final fingerprint = _externalClipboardFingerprint(payload);
    if (fingerprint != null) {
      final alreadyQueued = _pendingExternalClipboardPayloads.any(
        (candidate) => _externalClipboardFingerprint(candidate) == fingerprint,
      );
      if (alreadyQueued) {
        return;
      }
    }
    _pendingExternalClipboardPayloads.add(Map<String, dynamic>.from(payload));
  }

  // A stable signature for a native notification-sync event so we never queue
  // the same event twice (e.g. re-queued by a failed direct send *and* handed
  // to the flush path on reconnect). posted/updated carry postedAt; removed
  // carries removedAt — either disambiguates repeats for the same id.
  String? _notificationSyncEventSignature(Map<String, dynamic> event) {
    final eventType = event['eventType']?.toString();
    final notificationId = event['notificationId']?.toString();
    if (eventType == null ||
        eventType.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty) {
      return null;
    }
    final timestamp =
        (event['postedAt'] ?? event['removedAt'])?.toString() ?? '';
    return '$eventType\n$notificationId\n$timestamp';
  }

  void _enqueueNotificationSyncEvent(Map<String, dynamic> event) {
    final signature = _notificationSyncEventSignature(event);
    if (signature != null) {
      final alreadyQueued = _pendingNotificationSyncEvents.any(
        (queued) => _notificationSyncEventSignature(queued) == signature,
      );
      if (alreadyQueued) {
        return;
      }
    }
    _pendingNotificationSyncEvents.add(Map<String, dynamic>.from(event));
  }

  Future<void> _submitExternalClipboardPayload(
    Map<String, dynamic> payload,
  ) async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      _queuePendingExternalClipboardPayload(payload);
      client.connect().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[Android Clipboard] Failed to reconnect for clipboard send: $error',
        );
      });
      return;
    }

    if (_shouldSuppressExternalClipboardPayload(payload)) {
      return;
    }

    final contentType = payload['contentType']?.toString();
    final contentBase64 = payload['contentBase64']?.toString();
    final text = payload['text']?.toString();

    try {
      if (contentType != null &&
          contentType.isNotEmpty &&
          contentBase64 != null &&
          contentBase64.isNotEmpty) {
        final bytes = base64.decode(contentBase64);
        final result = await client.notifyClipboardChange(
          contentType: contentType,
          byteSize: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          contentBase64: contentBase64,
        );
        debugPrint(
          '[Android Clipboard] Forwarded $contentType to peers: '
          '${(result['broadcastTo'] as List?)?.join(', ') ?? '(none)'}',
        );
        return;
      }

      if (text != null && text.isNotEmpty) {
        final bytes = utf8.encode(text);
        final result = await client.notifyClipboardChange(
          contentType: 'text/plain',
          byteSize: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          contentBase64: base64Encode(bytes),
        );
        debugPrint(
          '[Android Clipboard] Forwarded text/plain to peers: '
          '${(result['broadcastTo'] as List?)?.join(', ') ?? '(none)'}',
        );
      }
    } catch (error) {
      debugPrint(
          '[Android Clipboard] Failed to submit external payload: $error');
    }
  }

  Future<void> _submitNativeNotificationSyncEvent(
    Map<String, dynamic> event,
  ) async {
    final eventType = event['eventType']?.toString();
    final notificationId = event['notificationId']?.toString();
    if (eventType == null ||
        eventType.isEmpty ||
        notificationId == null ||
        notificationId.isEmpty) {
      return;
    }

    // Always append to the FIFO queue and drain in order, even when connected.
    // Sending inline here while the flush path drains the backlog could let a
    // newer event (e.g. "removed") overtake an older queued one (its "posted"),
    // leaving a stale mirrored record on the daemon.
    _enqueueNotificationSyncEvent(event);
    await _flushPendingNotificationSyncEvents();
  }

  Future<void> _flushPendingNotificationSyncEvents() async {
    if (_isFlushingNotificationSyncEvents) {
      return;
    }
    final client = context.read<JsonRpcRiftClient>();
    _isFlushingNotificationSyncEvents = true;
    try {
      while (_pendingNotificationSyncEvents.isNotEmpty) {
        if (!client.isConnected) {
          client.connect().catchError((Object error, StackTrace stackTrace) {
            debugPrint(
              '[Notification Sync] Failed to reconnect for native event send: $error',
            );
          });
          // Leave the backlog intact; the reconnect will re-trigger the flush
          // via onConnectionChanged.
          return;
        }

        // Peek without removing so a mid-flight failure keeps the event queued
        // in its original position, preserving ordering.
        final event = _pendingNotificationSyncEvents.first;
        final eventType = event['eventType']?.toString() ?? '';
        try {
          await client.notifyLocalNotificationEvent(
            eventType: eventType,
            payload: Map<String, Object?>.from(event),
          );
          _pendingNotificationSyncEvents.removeAt(0);
        } catch (error) {
          debugPrint(
            '[Notification Sync] Failed to submit native notification event: $error',
          );
          return;
        }
      }
    } finally {
      _isFlushingNotificationSyncEvents = false;
    }
  }

  Future<void> _flushPendingExternalClipboardPayloads() async {
    if (_pendingExternalClipboardPayloads.isEmpty) {
      return;
    }

    final queued = List<Map<String, dynamic>>.from(
      _pendingExternalClipboardPayloads,
    );
    _pendingExternalClipboardPayloads.clear();
    for (final payload in queued) {
      await _submitExternalClipboardPayload(payload);
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
        _submitDesktopNotificationAction(
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
        unawaited(_submitExternalClipboardPayload(payload));
        return;
      case NotificationRoute.historySend:
        if (payload['items'] is List) {
          final items = List<Map<String, String>>.from(
            (payload['items'] as List).map(
              (item) => Map<String, String>.from(item as Map),
            ),
          );
          unawaited(_enqueueSharedSendItems(items));
        }
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
      case NotificationRoute.historyClipboard:
      case NotificationRoute.historyNotifications:
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
      case NotificationRoute.pairing:
        _openIncomingPairingRequest(payload);
        return;
      case NotificationRoute.historyIncomingOffers:
      case NotificationRoute.historyTransferActivity:
        _appShellKey.currentState?.showHistoryRoute(route);
        return;
    }
  }

  Future<void> _enqueueSharedSendItems(
    List<Map<String, String>> items,
  ) async {
    if (items.isEmpty) {
      return;
    }
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      _pendingSharedSendItems.addAll(items);
      debugPrint(
        '[Send Queue] Buffered ${items.length} shared item(s); daemon not connected yet.',
      );
      return;
    }
    final result = await context.read<SendQueueController>().enqueueRequests(
          items,
        );
    debugPrint(
      '[Send Queue] Enqueued shared items: added=${result.added} skipped=${result.skipped}',
    );
  }

  Future<void> _flushPendingSharedSendItems() async {
    if (_pendingSharedSendItems.isEmpty) {
      return;
    }
    final pending = List<Map<String, String>>.from(_pendingSharedSendItems);
    _pendingSharedSendItems.clear();
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      // Put them back; we'll try again on the next reconnect.
      _pendingSharedSendItems.insertAll(0, pending);
      return;
    }
    final result = await context.read<SendQueueController>().enqueueRequests(
          pending,
        );
    debugPrint(
      '[Send Queue] Drained buffered shared items: added=${result.added} skipped=${result.skipped}',
    );
    // If anything still couldn't be enqueued (e.g., file disappeared), re-buffer
    // so we don't lose the user's intent — they'll see it once the daemon
    // recovers and can act on it.
    if (result.skipped > 0 &&
        !_pendingSharedSendItems.contains(pending.first)) {
      debugPrint(
        '[Send Queue] ${result.skipped} shared item(s) still could not be enqueued after reconnect.',
      );
    }
  }

  void _queuePendingDesktopNotificationAction({
    required String notificationId,
    required String action,
  }) {
    final alreadyQueued = _pendingDesktopNotificationActions.any(
      (candidate) =>
          candidate['notificationId'] == notificationId &&
          candidate['action'] == action,
    );
    if (alreadyQueued) {
      return;
    }
    _pendingDesktopNotificationActions.add(<String, String>{
      'notificationId': notificationId,
      'action': action,
    });
  }

  Future<void> _submitDesktopNotificationAction({
    required String notificationId,
    required String action,
  }) async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      _queuePendingDesktopNotificationAction(
        notificationId: notificationId,
        action: action,
      );
      client.connect().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[Notification Sync] Failed to reconnect for notification action: $error',
        );
      });
      return;
    }

    try {
      await client.performNotificationAction(
        notificationId: notificationId,
        action: action,
      );
    } catch (error) {
      debugPrint(
        '[Notification Sync] Failed to perform mirrored notification action: $error',
      );
    }
  }

  Future<void> _flushPendingDesktopNotificationActions() async {
    if (_pendingDesktopNotificationActions.isEmpty) {
      return;
    }
    final pending = List<Map<String, String>>.from(
      _pendingDesktopNotificationActions,
    );
    _pendingDesktopNotificationActions.clear();
    for (final action in pending) {
      await _submitDesktopNotificationAction(
        notificationId: action['notificationId'] ?? '',
        action: action['action'] ?? '',
      );
    }
  }

  void _openIncomingPairingRequest(Map<String, dynamic> payload) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    final deviceId = payload['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }
    if (_activePairingDeviceId == deviceId) {
      return;
    }

    _activePairingDeviceId = deviceId;
    navigator
        .push(
      MaterialPageRoute<void>(
        builder: (_) => PairingScreen(
          initialDeviceId: deviceId,
          initialDisplayName: payload['displayName']?.toString(),
          initialPeerFingerprint: payload['fingerprint']?.toString(),
          initialExpiresInMs: (payload['expiresInMs'] as num?)?.toInt(),
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
    _pairingCompleteSub?.cancel();
    _trustChangedSub?.cancel();
    _fileOfferSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    _notificationPostedSub?.cancel();
    _notificationUpdatedSub?.cancel();
    _notificationRemovedSub?.cancel();
    _connectionChangedSub?.cancel();
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
    _maybeNotifyWithRoute(title: title, body: body);
  }

  Future<bool> _clipboardNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppPrefs.clipboardNotificationsEnabled) ?? false;
  }

  void _maybeNotifyCompletedTransfer({
    required String title,
    required String body,
    String? destinationPath,
  }) {
    unawaited(() async {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final foreground = await _isWindowForeground();
        if (foreground) return;
      }
      try {
        if (Platform.isWindows &&
            destinationPath != null &&
            destinationPath.trim().isNotEmpty) {
          await WindowsShell.showTransferNotification(
            title: title,
            body: body,
            destinationPath: destinationPath,
          );
          return;
        }
        if (Platform.isAndroid &&
            destinationPath != null &&
            destinationPath.trim().isNotEmpty) {
          await AndroidShell.showNotification(
            title: title,
            body: body,
            route: NotificationRoute.historyTransferActivity,
            destinationPath: destinationPath,
            payload: const <String, Object?>{'openDestination': true},
          );
          return;
        }
        _maybeNotifyWithRoute(
          title: title,
          body: body,
          route: NotificationRoute.historyTransferActivity,
          destinationPath: destinationPath,
        );
      } catch (_) {
        // Best-effort.
      }
    }());
  }

  void _maybeNotifyWithRoute({
    required String title,
    required String body,
    String? route,
    String? destinationPath,
    Map<String, Object?>? payload,
  }) {
    unawaited(() async {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final foreground = await _isWindowForeground();
        if (foreground) return;
      }
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

  List<DesktopNotificationAction> _buildMirroredNotificationActions(
    Map<String, dynamic> event,
  ) {
    final actions = <DesktopNotificationAction>[];
    if (event['isOpenable'] == true) {
      actions.add(
        const DesktopNotificationAction(id: 'open', title: 'Open'),
      );
    }
    if (event['isDismissible'] == true) {
      actions.add(
        const DesktopNotificationAction(id: 'dismiss', title: 'Dismiss'),
      );
    }
    return actions;
  }

  void _showMirroredNotificationPreview(Map<String, dynamic> event) {
    if (Platform.isAndroid) {
      return;
    }
    final notificationId = event['notificationId']?.toString();
    if (notificationId == null || notificationId.isEmpty) {
      return;
    }
    final title = event['title']?.toString().trim();
    final body = event['bodyPreview']?.toString().trim();
    final appName = event['appName']?.toString().trim();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    final mirroredPayload = <String, Object?>{
      'route': NotificationRoute.historyNotifications,
      'notificationId': notificationId,
      if (sourceDeviceId != null && sourceDeviceId.isNotEmpty)
        'sourceDeviceId': sourceDeviceId,
      if (appName != null && appName.isNotEmpty) 'appName': appName,
      'isOpenable': event['isOpenable'] == true,
      'isDismissible': event['isDismissible'] == true,
    };
    final mirroredActions = _buildMirroredNotificationActions(event);
    final notificationTitle = (title != null && title.isNotEmpty)
        ? title
        : ((appName != null && appName.isNotEmpty) ? appName : 'Notification');
    final notificationBody = [
      if (sourceDeviceId != null && sourceDeviceId.isNotEmpty) sourceDeviceId,
      if (body != null && body.isNotEmpty) body,
    ].join(' • ');

    unawaited(() async {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final foreground = await _isWindowForeground();
        if (foreground) return;
      }
      try {
        if (Platform.isWindows) {
          await WindowsShell.showNotification(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
          );
          return;
        }
        if (Platform.isLinux) {
          await LinuxNotifications.show(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
            actions: mirroredActions,
          );
          return;
        }
        if (Platform.isMacOS) {
          await MacOSNotifications.show(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
            actions: mirroredActions,
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

  void _bindPairingRequests() {
    final client = context.read<JsonRpcRiftClient>();
    _pairingRequestSub = client.onPairingRequest.listen((event) {
      if (!mounted) return;

      final deviceId = event['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return;

      final displayName = event['displayName']?.toString();
      _maybeNotifyWithRoute(
        title: 'Pairing request',
        body: displayName == null || displayName.isEmpty
            ? 'Incoming pairing request.'
            : 'Incoming pairing request from $displayName.',
        route: NotificationRoute.pairing,
        payload: <String, Object?>{
          'deviceId': deviceId,
          if (displayName != null && displayName.isNotEmpty)
            'displayName': displayName,
          if (event['fingerprint'] != null)
            'fingerprint': event['fingerprint'].toString(),
          if (event['expiresInMs'] != null)
            'expiresInMs': event['expiresInMs'] as Object,
        },
      );
      _openIncomingPairingRequest({
        'deviceId': deviceId,
        'displayName': displayName,
        'fingerprint': event['fingerprint']?.toString(),
        'expiresInMs': event['expiresInMs'],
      });
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

    _pairingCompleteSub = client.onPairingComplete.listen((event) {
      final deviceId = event['deviceId']?.toString() ?? 'trusted device';
      final displayName = event['displayName']?.toString();
      final label = (displayName != null && displayName.isNotEmpty)
          ? displayName
          : deviceId;
      _maybeNotifyWithRoute(
        title: 'Pairing completed',
        body: 'Connected to $label.',
        route: NotificationRoute.devices,
      );
    });

    _clipboardOfferSub = client.onClipboardOffer.listen((event) {
      final contentType = event['contentType']?.toString() ?? '';
      final offerId = event['offerId']?.toString();
      final sourceDeviceId =
          event['sourceDeviceId']?.toString() ?? 'trusted device';
      final isImage = contentType.startsWith('image/');
      final clipboardTitle = isImage ? 'Image received' : 'Text received';
      final clipboardBody = isImage
          ? 'Image clipboard synced from $sourceDeviceId.'
          : 'Text clipboard synced from $sourceDeviceId.';

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
            if (await _clipboardNotificationsEnabled()) {
              _maybeNotifyWithRoute(
                title: clipboardTitle,
                body: clipboardBody,
                route: NotificationRoute.historyClipboard,
              );
            }
          } catch (e) {
            debugPrint('Auto-fetch clipboard failed: $e');
          }
        }());
      } else {
        unawaited(() async {
          if (await _clipboardNotificationsEnabled()) {
            _maybeNotifyWithRoute(
              title: clipboardTitle,
              body: clipboardBody,
              route: NotificationRoute.historyClipboard,
            );
          }
        }());
      }
    });

    _clipboardExpiredSub = client.onClipboardExpired.listen((event) {
      // Intentionally left empty to avoid noisy notifications
    });

    _notificationPostedSub = client.onNotificationPosted.listen((event) {
      _showMirroredNotificationPreview(event);
    });

    _notificationUpdatedSub = client.onNotificationUpdated.listen((event) {
      // History UI refreshes from its own stream binding; updates do not raise a
      // second native popup to avoid noisy duplicates.
    });

    _notificationRemovedSub = client.onNotificationRemoved.listen((event) {
      // Native notifications are best-effort previews; removal only updates the
      // in-app history state.
    });

    _fileOfferSub = client.onFileOffer.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final sourceDeviceId =
          event['sourceDeviceId']?.toString() ?? 'trusted device';
      _maybeNotifyWithRoute(
        title: 'Incoming file',
        body: '$fileName from $sourceDeviceId.',
        route: NotificationRoute.historyIncomingOffers,
      );
      unawaited(_handleIncomingFileOffer(event));
    });

    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final peer = event['peerDeviceId']?.toString() ?? 'trusted device';
      final destinationPath = event['destinationPath']?.toString();
      final isIncoming =
          destinationPath != null && destinationPath.trim().isNotEmpty;
      _maybeNotify(
        isIncoming ? 'File received' : 'File sent',
        destinationPath == null || destinationPath.trim().isEmpty
            ? '$fileName ${isIncoming ? 'received from' : 'sent to'} $peer.'
            : '$fileName saved to $destinationPath.',
      );
      _maybeNotifyCompletedTransfer(
        title: isIncoming ? 'File received' : 'File sent',
        body: destinationPath == null || destinationPath.trim().isEmpty
            ? '$fileName ${isIncoming ? 'received from' : 'sent to'} $peer.'
            : '$fileName saved to $destinationPath.',
        destinationPath: destinationPath,
      );
    });

    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      final fileName = event['fileName']?.toString() ?? 'file';
      final reason = event['failureReason']?.toString() ?? 'failed';
      _maybeNotifyWithRoute(
        title: 'File transfer failed',
        body: '$fileName failed: $reason.',
        route: NotificationRoute.historyTransferActivity,
      );
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
      final destinationPath = await buildDefaultIncomingFilePath(fileName);
      if (destinationPath == null || destinationPath.isEmpty) {
        throw const FileSystemException(
          'Could not resolve a public Downloads/Rift save location.',
        );
      }

      final shouldAccept = await _confirmIncomingFileOffer(
        fileName: fileName,
        sourceDeviceId: sourceDeviceId,
        destinationPath: destinationPath,
      );
      if (shouldAccept != true) {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'User declined incoming file transfer.',
        );
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Declined $fileName from $sourceDeviceId')),
        );
        return;
      }

      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Receiving $fileName from $sourceDeviceId...\n'
            'Saved to: $destinationPath',
          ),
        ),
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
          message: 'Incoming file transfer could not be confirmed.',
        );
      } catch (_) {
        // Best-effort reject if incoming transfer setup fails.
      }
      _maybeNotifyWithRoute(
        title: 'Incoming file failed',
        body: 'Could not auto-save $fileName: $error',
        route: NotificationRoute.historyTransferActivity,
      );
    } finally {
      _autoAcceptingTransferIds.remove(transferId);
    }
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
  final ValueNotifier<String?>? historyRouteNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  const AppShell({
    super.key,
    this.historyRouteNotifier,
    this.sharedClipboardTextNotifier,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;

  late final List<Widget> _screens = [
    const TrustedDevicesScreen(),
    ClipboardTransferScreen(
      routeNotifier: widget.historyRouteNotifier,
      sharedClipboardTextNotifier: widget.sharedClipboardTextNotifier,
    ),
    const SecurityDashboardScreen(),
    const OperationsScreen(),
  ];

  void showHistoryRoute(String route) {
    setState(() {
      _currentIndex = 1;
    });
    widget.historyRouteNotifier?.value = route;
  }

  void showRoute(String route) {
    if (route == NotificationRoute.devices) {
      setState(() {
        _currentIndex = 0;
      });
      return;
    }
    showHistoryRoute(route);
  }

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
