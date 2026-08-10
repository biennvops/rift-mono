import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:flutter/services.dart';

import 'constants.dart';
import 'src/ui/app_shell.dart' as rift_ui;
import 'src/ui/theme.dart';
import 'screens/pairing_screen.dart';
import 'screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/ipc/android_background_entrypoint.dart';
import 'src/ipc/json_rpc_client.dart';
import 'src/ipc/transport_factory.dart';
import 'src/notification_sync_policy.dart';
import 'src/notification_icon.dart';
import 'src/notification_mirror_identity.dart';
import 'src/mirrored_notification_registry.dart';
import 'src/mirrored_notification_reconciliation.dart';
import 'src/trusted_peer_name_resolver.dart';
import 'src/clipboard/desktop_clipboard_manager.dart';
import 'src/file_transfer/file_storage.dart';
import 'src/file_transfer/send_queue_controller.dart';
import 'src/device_status/device_status_publisher.dart';
import 'src/ui/local_events_notifier.dart';
import 'src/platform/android_shell.dart';
import 'src/media_playback/ios_remote_media_playback_coordinator.dart';
import 'src/media_playback/macos_remote_media_playback_coordinator.dart';
import 'src/media_playback/windows_media_playback_publisher.dart';
import 'src/media_playback/windows_remote_media_playback_coordinator.dart';
import 'src/platform/macos_send_files.dart';
import 'src/platform/ios_notifications.dart';
import 'src/platform/linux_notifications.dart';
import 'src/platform/linux_send_files.dart';
import 'src/platform/macos_notifications.dart';
import 'src/platform/notification_route.dart';
import 'src/platform/windows_send_files.dart';
import 'src/platform/windows_shell.dart';

const _desktopClipboardChannel = MethodChannel('rift/desktop/clipboard');
String? _lastDesktopClipboardReadFingerprint;

@visibleForTesting
void setMacOSNotificationBridgeOverride(bool? value) {
  // ignore: invalid_use_of_visible_for_testing_member
  MacOSNotifications.debugIsMacOSOverride = value;
}

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

@visibleForTesting
bool shouldStartDesktopHidden(List<String> arguments) =>
    arguments.contains('--background');

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

  if (Platform.isAndroid) {
    return DesktopClipboardManager(
      client,
      autoApplyIncomingOffers: false,
    );
  }

  return DesktopClipboardManager(client);
}

@pragma('vm:entry-point')
Future<void> androidBackgroundMain() => runAndroidBackgroundMain();

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final startDesktopHidden = isDesktop && shouldStartDesktopHidden(arguments);
  if (isDesktop) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(800, 600),
      center: true,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
      if (startDesktopHidden) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
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
          value: clipboardManager,
        ),
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
  static const Duration _externalClipboardDuplicateWindow =
      Duration(seconds: 2);

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<rift_ui.AppShellState> _appShellKey =
      GlobalKey<rift_ui.AppShellState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<Map<String, dynamic>>? _pairingCompleteSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileReadyToCommitSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardOfferSub;
  StreamSubscription<Map<String, dynamic>>? _clipboardExpiredSub;
  StreamSubscription<Map<String, dynamic>>? _notificationPostedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _notificationRemovedSub;
  StreamSubscription<bool>? _connectionChangedSub;
  String? _activePairingDeviceId;
  DesktopClipboardManager? _clipboardManager;
  final Set<String> _autoAcceptingTransferIds = <String>{};
  final Set<String> _publishingTransferIds = <String>{};
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
  IOSRemoteMediaPlaybackCoordinator? _iosRemoteMediaPlayback;
  MacOSRemoteMediaPlaybackCoordinator? _macOSRemoteMediaPlayback;
  WindowsMediaPlaybackPublisher? _windowsMediaPlaybackPublisher;
  WindowsRemoteMediaPlaybackCoordinator? _windowsRemoteMediaPlayback;
  DeviceStatusPublisher? _deviceStatusPublisher;
  TrustedPeerNameResolver? _trustedPeerNameResolver;
  String? _lastExternalClipboardFingerprint;
  DateTime? _lastExternalClipboardAt;
  Future<String?>? _localDeviceIdFuture;
  Future<MirroredNotificationRegistry>? _mirroredNotificationRegistryFuture;
  Future<void>? _reconciliationInFlight;
  Future<void> _mirroredNotificationLifecycleQueue = Future<void>.value();

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
      _bindMediaPlayback();
      _bindDeviceStatus();
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

  void _bindDeviceStatus() {
    if (Platform.isAndroid ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _deviceStatusPublisher = DeviceStatusPublisher(
      context.read<JsonRpcRiftClient>(),
    );
    unawaited(_deviceStatusPublisher!.start());
  }

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
    IOSNotifications.setMethodCallHandler(
      _handlePlatformNotificationMethodCall,
    );
    if (Platform.isLinux) {
      LinuxSendFiles.setMethodCallHandler(_handleLinuxSendFilesMethodCall);
      unawaited(_consumePendingLinuxSendItems());
    }
    if (Platform.isMacOS) {
      MacOSSendFiles.setMethodCallHandler(_handleMacOSSendFilesMethodCall);
    }
    if (Platform.isWindows) {
      WindowsSendFiles.setMethodCallHandler(_handleWindowsSendFilesMethodCall);
      unawaited(_consumePendingWindowsSendItems());
    }
    AndroidShell.setMethodCallHandler(_handlePlatformNotificationMethodCall);

    if (IOSNotifications.isSupported) {
      final pendingAction = await IOSNotifications.consumeLaunchAction();
      if (pendingAction != null) {
        _handleNotificationActionPayload(pendingAction);
      }
    }

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
        unawaited(_recoverPendingFileCommits());
        unawaited(_handleConnectionRestored(client));
      }
    });
  }

  Future<void> _refreshTrustedPeerNames() async {
    final resolver = _trustedPeerNameResolver;
    if (resolver == null) {
      return;
    }
    try {
      await resolver.refresh();
    } catch (error) {
      debugPrint(
        '[Trusted Peer Names] Failed to refresh peer names: $error',
      );
    }
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

  Future<void> _handleConnectionRestored(JsonRpcRiftClient client) async {
    await _reapplyNotificationSyncPolicy(client);
    await _refreshTrustedPeerNames();
    await _reconcileMirroredNotificationPreviews();
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

  void _bindMediaPlayback() {
    final client = context.read<JsonRpcRiftClient>();
    if (Platform.isIOS) {
      _iosRemoteMediaPlayback = IOSRemoteMediaPlaybackCoordinator(client);
      unawaited(_iosRemoteMediaPlayback!.start());
    } else if (Platform.isMacOS) {
      _macOSRemoteMediaPlayback = MacOSRemoteMediaPlaybackCoordinator(client);
      unawaited(_macOSRemoteMediaPlayback!.start());
    } else if (Platform.isWindows) {
      _windowsMediaPlaybackPublisher = WindowsMediaPlaybackPublisher(client);
      _windowsRemoteMediaPlayback =
          WindowsRemoteMediaPlaybackCoordinator(client);
      unawaited(_windowsMediaPlaybackPublisher!.start());
      unawaited(_windowsRemoteMediaPlayback!.start());
    }
  }

  Future<void> _consumePendingLinuxSendItems() async {
    final pendingItems = await LinuxSendFiles.consumePendingItems();
    if (pendingItems.isEmpty) {
      return;
    }
    await _enqueueSharedSendItems(pendingItems);
    _showHistoryRoute(NotificationRoute.historySend);
  }

  Future<dynamic> _handleLinuxSendFilesMethodCall(MethodCall call) async {
    if (call.method != LinuxSendFiles.callbackMethod) {
      return null;
    }

    final items = LinuxSendFiles.parseCallbackArguments(call.arguments);
    if (items.isEmpty) {
      return null;
    }

    unawaited(_enqueueSharedSendItems(items));
    _showHistoryRoute(NotificationRoute.historySend);
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
    _showHistoryRoute(NotificationRoute.historySend);
    return null;
  }

  Future<void> _consumePendingWindowsSendItems() async {
    final pendingItems = await WindowsSendFiles.consumePendingItems();
    if (pendingItems.isEmpty) {
      return;
    }
    await _enqueueSharedSendItems(pendingItems);
    _showHistoryRoute(NotificationRoute.historySend);
  }

  Future<dynamic> _handleWindowsSendFilesMethodCall(MethodCall call) async {
    if (call.method != WindowsSendFiles.callbackMethod) {
      return null;
    }

    final items = WindowsSendFiles.parseCallbackArguments(call.arguments);
    if (items.isEmpty) {
      return null;
    }

    unawaited(_enqueueSharedSendItems(items));
    _showHistoryRoute(NotificationRoute.historySend);
    return null;
  }

  void _showHistoryRoute(String route) {
    final shell = _appShellKey.currentState;
    if (shell == null) {
      _historyRouteNotifier.value = route;
    } else {
      shell.showHistoryRoute(route);
    }

    if (_enableDesktopShellIntegration) {
      unawaited(_clipboardManager?.setWindowVisible(true));
      unawaited(windowManager.show());
      unawaited(windowManager.focus());
    }
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
    final sourceDeviceId = payload['sourceDeviceId']?.toString();
    final notificationId = payload['notificationId']?.toString();
    if (notificationAction != null &&
        sourceDeviceId != null &&
        sourceDeviceId.isNotEmpty &&
        notificationId != null &&
        notificationId.isNotEmpty) {
      unawaited(
        _submitDesktopNotificationAction(
          sourceDeviceId: sourceDeviceId,
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
        _showHistoryRoute(route);
        return;
      case NotificationRoute.historyClipboard:
      case NotificationRoute.historyNotifications:
        _showHistoryRoute(route);
        return;
      case NotificationRoute.pairing:
        _openIncomingPairingRequest(payload);
        return;
      case NotificationRoute.historyIncomingOffers:
      case NotificationRoute.historyTransferActivity:
        _showHistoryRoute(route);
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
    required String sourceDeviceId,
    required String notificationId,
    required String action,
  }) {
    final alreadyQueued = _pendingDesktopNotificationActions.any(
      (candidate) =>
          candidate['sourceDeviceId'] == sourceDeviceId &&
          candidate['notificationId'] == notificationId &&
          candidate['action'] == action,
    );
    if (alreadyQueued) {
      return;
    }
    _pendingDesktopNotificationActions.add(<String, String>{
      'sourceDeviceId': sourceDeviceId,
      'notificationId': notificationId,
      'action': action,
    });
  }

  Future<bool> _submitDesktopNotificationAction({
    required String sourceDeviceId,
    required String notificationId,
    required String action,
    bool queueIfUnavailable = true,
  }) async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      if (queueIfUnavailable) {
        _queuePendingDesktopNotificationAction(
          sourceDeviceId: sourceDeviceId,
          notificationId: notificationId,
          action: action,
        );
      }
      client.connect().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[Notification Sync] Failed to reconnect for notification action: $error',
        );
      });
      return false;
    }

    try {
      await client.performNotificationAction(
        sourceDeviceId: sourceDeviceId,
        notificationId: notificationId,
        action: action,
      );
      return true;
    } catch (error) {
      debugPrint(
        '[Notification Sync] Failed to perform mirrored notification action: $error',
      );
      if (queueIfUnavailable) {
        _queuePendingDesktopNotificationAction(
          sourceDeviceId: sourceDeviceId,
          notificationId: notificationId,
          action: action,
        );
      }
      return false;
    }
  }

  Future<void> _flushPendingDesktopNotificationActions() async {
    while (_pendingDesktopNotificationActions.isNotEmpty) {
      final action = Map<String, String>.from(
        _pendingDesktopNotificationActions.first,
      );
      final submitted = await _submitDesktopNotificationAction(
        sourceDeviceId: action['sourceDeviceId'] ?? '',
        notificationId: action['notificationId'] ?? '',
        action: action['action'] ?? '',
        queueIfUnavailable: false,
      );
      if (!submitted) {
        break;
      }
      _pendingDesktopNotificationActions.removeAt(0);
    }
  }

  void _openIncomingPairingRequest(Map<String, dynamic> payload) {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) {
      return;
    }

    final deviceId = payload['deviceId']?.toString();
    final fingerprint = payload['fingerprint']?.toString();
    if (deviceId == null ||
        deviceId.isEmpty ||
        fingerprint == null ||
        fingerprint.isEmpty) {
      return;
    }
    if (_activePairingDeviceId == deviceId) {
      return;
    }

    _activePairingDeviceId = deviceId;
    showDialog<void>(
      context: navContext,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => PairingScreen.incoming(
        deviceId: deviceId,
        displayName: payload['displayName']?.toString(),
        fingerprint: fingerprint,
        expiresInMs: (payload['expiresInMs'] as num?)?.toInt(),
      ),
    ).whenComplete(() {
      if (mounted && _activePairingDeviceId == deviceId) {
        _activePairingDeviceId = null;
      }
    });
  }

  Future<void> _initSystemTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows
            ? 'windows/runner/resources/app_icon.ico'
            : Platform.isLinux
                ? 'assets/dev.rift.Rift.png'
                : 'app_icon.png',
      );
      await trayManager.setToolTip(AppStrings.appTitle);
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
    _fileReadyToCommitSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    _clipboardOfferSub?.cancel();
    _clipboardExpiredSub?.cancel();
    _notificationPostedSub?.cancel();
    _notificationUpdatedSub?.cancel();
    _notificationRemovedSub?.cancel();
    _connectionChangedSub?.cancel();
    unawaited(_iosRemoteMediaPlayback?.dispose());
    unawaited(_macOSRemoteMediaPlayback?.dispose());
    unawaited(_windowsMediaPlaybackPublisher?.dispose());
    unawaited(_windowsRemoteMediaPlayback?.dispose());
    unawaited(_deviceStatusPublisher?.dispose());
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
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
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
      try {
        if (IOSNotifications.isSupported) {
          await IOSNotifications.show(
            title: title,
            body: body,
            route: route,
            destinationPath: destinationPath,
            payload: payload,
          );
          return;
        }
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
        if (MacOSNotifications.supportsPendingShareHandoff) {
          await MacOSNotifications.show(
            title: title,
            body: body,
            route: route,
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

  Future<String?> _getLocalDeviceId() {
    return _localDeviceIdFuture ??= () async {
      try {
        final result = await context.read<JsonRpcRiftClient>().getDeviceInfo();
        if (result is Map) {
          final deviceId = result['deviceId']?.toString();
          if (deviceId != null && deviceId.isNotEmpty) {
            return deviceId;
          }
        }
      } catch (_) {
        _localDeviceIdFuture = null;
      }
      return null;
    }();
  }

  Future<MirroredNotificationRegistry> _getMirroredNotificationRegistry() {
    return _mirroredNotificationRegistryFuture ??=
        MirroredNotificationRegistry.load();
  }

  Future<void> _enqueueMirroredNotificationLifecycle(
    Future<void> Function() operation,
  ) {
    final next = _mirroredNotificationLifecycleQueue.then<void>(
      (_) => operation(),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
            '[Notification Mirror] Previous lifecycle operation failed: $error');
        return operation();
      },
    );
    _mirroredNotificationLifecycleQueue = next;
    unawaited(
      next.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          debugPrint(
              '[Notification Mirror] Lifecycle operation failed: $error');
        },
      ),
    );
    return next;
  }

  Future<bool> _showNativeMirroredNotification({
    required String mirrorKey,
    required String title,
    required String body,
    required Map<String, Object?> payload,
    required List<DesktopNotificationAction> actions,
    required Map<String, dynamic> event,
    required bool isUpdate,
    Uint8List? iconBytes,
  }) async {
    // Replacing a delivered UNNotificationRequest alerts again on Apple.
    if (isUpdate &&
        (IOSNotifications.isSupported ||
            MacOSNotifications.supportsPendingShareHandoff)) {
      return false;
    }

    try {
      if (IOSNotifications.isSupported) {
        return await IOSNotifications.show(
          title: title,
          body: body,
          route: NotificationRoute.historyNotifications,
          payload: payload,
          notificationKey: mirrorKey,
        );
      }
      if (Platform.isAndroid) {
        final sourcePlatform = event['sourcePlatform']?.toString();
        if (sourcePlatform != 'windows' &&
            sourcePlatform != 'macos' &&
            sourcePlatform != 'linux') {
          return false;
        }
        return await AndroidShell.showNotification(
          title: title,
          body: body,
          route: NotificationRoute.historyNotifications,
          payload: payload,
          notificationKey: mirrorKey,
          iconBytes: iconBytes,
        );
      }
      if (Platform.isWindows) {
        return await WindowsShell.showNotification(
          title: title,
          body: body,
          route: NotificationRoute.historyNotifications,
          payload: payload,
          notificationKey: mirrorKey,
          iconBytes: iconBytes,
        );
      }
      if (MacOSNotifications.supportsPendingShareHandoff) {
        return await MacOSNotifications.show(
          title: title,
          body: body,
          route: NotificationRoute.historyNotifications,
          payload: payload,
          actions: actions,
          notificationKey: mirrorKey,
        );
      }
      if (Platform.isLinux) {
        return await LinuxNotifications.show(
          title: title,
          body: body,
          route: NotificationRoute.historyNotifications,
          payload: payload,
          actions: actions,
          notificationKey: mirrorKey,
          iconBytes: iconBytes,
        );
      }
    } catch (error) {
      debugPrint('[Notification Mirror] Native show failed: $error');
    }
    return false;
  }

  Future<bool> _clearNativeMirroredNotification(String mirrorKey) async {
    try {
      if (IOSNotifications.isSupported) {
        return await IOSNotifications.clearNotification(mirrorKey);
      }
      if (Platform.isAndroid) {
        return await AndroidShell.clearNotification(mirrorKey);
      }
      if (Platform.isWindows) {
        return await WindowsShell.clearNotification(mirrorKey);
      }
      if (MacOSNotifications.supportsPendingShareHandoff) {
        return await MacOSNotifications.clearNotification(mirrorKey);
      }
      if (Platform.isLinux) {
        return await LinuxNotifications.clearNotification(mirrorKey);
      }
    } catch (error) {
      debugPrint('[Notification Mirror] Native clear failed: $error');
    }
    return false;
  }

  Future<void> _showOrUpdateMirroredNotificationPreview(
    Map<String, dynamic> event, {
    required bool isUpdate,
  }) async {
    final notificationId = event['notificationId']?.toString();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    if (notificationId == null ||
        notificationId.isEmpty ||
        sourceDeviceId == null ||
        sourceDeviceId.isEmpty) {
      return;
    }

    final localDeviceId = await _getLocalDeviceId();
    if (localDeviceId == null || sourceDeviceId == localDeviceId) {
      return;
    }

    final mirrorKey = mirroredNotificationKey(
      sourceDeviceId: sourceDeviceId,
      notificationId: notificationId,
    );
    final title = event['title']?.toString().trim();
    final body = event['bodyPreview']?.toString().trim();
    final appName = event['appName']?.toString().trim();
    final mirroredPayload = <String, Object?>{
      'route': NotificationRoute.historyNotifications,
      'notificationId': notificationId,
      'sourceDeviceId': sourceDeviceId,
      if (appName != null && appName.isNotEmpty) 'appName': appName,
      'isOpenable': event['isOpenable'] == true,
      'isDismissible': event['isDismissible'] == true,
    };
    final mirroredActions = _buildMirroredNotificationActions(event);
    final iconBytes = parseNotificationIcon(event['icon'])?.bytes;
    final notificationTitle = (title != null && title.isNotEmpty)
        ? title
        : ((appName != null && appName.isNotEmpty) ? appName : 'Notification');

    try {
      final resolver = _trustedPeerNameResolver;
      final sourceDeviceName =
          resolver == null ? null : await resolver.resolve(sourceDeviceId);
      final notificationBody = [
        if (sourceDeviceName != null && sourceDeviceName.isNotEmpty)
          sourceDeviceName,
        if (body != null && body.isNotEmpty) body,
      ].join(' • ');
      final shown = await _showNativeMirroredNotification(
        mirrorKey: mirrorKey,
        title: notificationTitle,
        body: notificationBody,
        payload: mirroredPayload,
        actions: mirroredActions,
        event: event,
        isUpdate: isUpdate,
        iconBytes: iconBytes,
      );
      if (shown) {
        await (await _getMirroredNotificationRegistry()).remember(
          MirroredNotificationEntry(
            mirrorKey: mirrorKey,
            sourceDeviceId: sourceDeviceId,
            notificationId: notificationId,
          ),
        );
      }
    } catch (error) {
      debugPrint(
          '[Notification Mirror] Failed to show mirrored preview: $error');
    }
  }

  Future<void> _clearMirroredNotificationPreview(
    Map<String, dynamic> event,
  ) async {
    final notificationId = event['notificationId']?.toString();
    final sourceDeviceId = event['sourceDeviceId']?.toString();
    if (notificationId == null ||
        notificationId.isEmpty ||
        sourceDeviceId == null ||
        sourceDeviceId.isEmpty) {
      return;
    }

    final localDeviceId = await _getLocalDeviceId();
    if (localDeviceId == null || sourceDeviceId == localDeviceId) {
      return;
    }

    final mirrorKey = mirroredNotificationKey(
      sourceDeviceId: sourceDeviceId,
      notificationId: notificationId,
    );
    final cleared = await _clearNativeMirroredNotification(mirrorKey);
    if (cleared) {
      await (await _getMirroredNotificationRegistry()).forget(mirrorKey);
    }
  }

  Future<void> _performMirroredNotificationReconciliation() async {
    final client = context.read<JsonRpcRiftClient>();
    final registry = await _getMirroredNotificationRegistry();
    await reconcileMirroredNotificationPreviews(
      client: client,
      registry: registry,
      getLocalDeviceId: _getLocalDeviceId,
      clearNativeNotification: _clearNativeMirroredNotification,
    );
  }

  Future<void> _reconcileMirroredNotificationPreviews() {
    final existing = _reconciliationInFlight;
    if (existing != null) {
      return existing;
    }

    final future = _enqueueMirroredNotificationLifecycle(
      _performMirroredNotificationReconciliation,
    );
    _reconciliationInFlight = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_reconciliationInFlight, future)) {
            _reconciliationInFlight = null;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_reconciliationInFlight, future)) {
            _reconciliationInFlight = null;
          }
          debugPrint('[Notification Mirror] Reconciliation failed: $error');
        },
      ),
    );
    return future;
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
    _trustedPeerNameResolver = TrustedPeerNameResolver(
      listTrustedPeers: () async {
        final result = await client.listTrustedPeers();
        if (result is Map) {
          return Map<String, dynamic>.from(result);
        }
        return <String, dynamic>{};
      },
    );
    unawaited(_refreshTrustedPeerNames());

    _trustChangedSub = client.onTrustChanged.listen((event) {
      _trustedPeerNameResolver!.applyTrustChanged(event);
      final deviceId = event['deviceId']?.toString() ?? 'unknown device';
      final newState = event['newState']?.toString();
      final reason = event['reason']?.toString() ?? '';
      if (newState == 'revoked' && reason.contains('remote')) {
        final displayName = event['displayName']?.toString() ?? deviceId;
        _maybeNotifyWithRoute(
          title: 'Trust revoked',
          body: '$displayName revoked trust with this device.',
          route: NotificationRoute.devices,
        );
      }
    });

    _pairingCompleteSub = client.onPairingComplete.listen((event) async {
      final deviceId = event['deviceId']?.toString();
      final eventName = event['displayName']?.toString();
      String label =
          (eventName != null && eventName.isNotEmpty) ? eventName : '';

      if (label.isEmpty && deviceId != null && deviceId.isNotEmpty) {
        try {
          final result = await client.listTrustedPeers();
          final peers =
              List<dynamic>.from((result as Map)['peers'] ?? const []);
          for (final candidate in peers) {
            if (candidate is! Map) continue;
            if (candidate['deviceId']?.toString() == deviceId) {
              final peerName = candidate['displayName']?.toString();
              if (peerName != null && peerName.isNotEmpty) {
                label = peerName;
                break;
              }
            }
          }
        } catch (_) {}
      }

      if (label.isEmpty) {
        label = (deviceId != null && deviceId.length > 16)
            ? '${deviceId.substring(0, 16)}...'
            : (deviceId ?? 'trusted device');
      }

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
      _enqueueMirroredNotificationLifecycle(
        () => _showOrUpdateMirroredNotificationPreview(
          event,
          isUpdate: false,
        ),
      );
    });

    _notificationUpdatedSub = client.onNotificationUpdated.listen((event) {
      _enqueueMirroredNotificationLifecycle(
        () => _showOrUpdateMirroredNotificationPreview(
          event,
          isUpdate: true,
        ),
      );
    });

    _notificationRemovedSub = client.onNotificationRemoved.listen((event) {
      _enqueueMirroredNotificationLifecycle(
        () => _clearMirroredNotificationPreview(event),
      );
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
      if (!Platform.isIOS) {
        unawaited(_handleIncomingFileOffer(event));
      }
    });

    _fileReadyToCommitSub = client.onFileTransferReadyToCommit.listen((event) {
      unawaited(_publishPendingFileCommit(event));
    });

    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      unawaited(_handleCompletedFileTransfer(event));
    });

    if (client.isConnected) {
      unawaited(_recoverPendingFileCommits());
      unawaited(_reconcileMirroredNotificationPreviews());
    }

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

  bool get _supportsDesktopFilePublication =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _recoverPendingFileCommits() async {
    if (!_supportsDesktopFilePublication) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      return;
    }
    try {
      final result = await client.listPendingFileCommits();
      if (result is! Map) {
        return;
      }
      final commits = result['commits'];
      if (commits is! List) {
        return;
      }
      for (final commit in commits.whereType<Map>()) {
        unawaited(
          _publishPendingFileCommit(Map<String, dynamic>.from(commit)),
        );
      }
    } catch (error) {
      if (!JsonRpcRiftClient.isMethodNotFoundError(error)) {
        debugPrint('[File Transfer] Failed to recover pending commits: $error');
      }
    }
  }

  Future<void> _publishPendingFileCommit(Map<String, dynamic> commit) async {
    if (!_supportsDesktopFilePublication) {
      return;
    }

    final transferId = commit['transferId']?.toString();
    final stagingPath = commit['stagingPath']?.toString();
    final destinationPath = commit['destinationPath']?.toString();
    final expectedSha256 = commit['sha256']?.toString();
    final byteSize = commit['byteSize'];
    if (transferId == null ||
        transferId.isEmpty ||
        stagingPath == null ||
        stagingPath.isEmpty ||
        destinationPath == null ||
        destinationPath.isEmpty ||
        expectedSha256 == null ||
        expectedSha256.isEmpty ||
        byteSize is! num ||
        !_publishingTransferIds.add(transferId)) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    try {
      final publishedPath = await publishVerifiedIncomingFile(
        transferId: transferId,
        stagingPath: stagingPath,
        destinationPath: destinationPath,
        expectedByteSize: byteSize.toInt(),
        expectedSha256: expectedSha256,
      );
      try {
        await client.confirmFileCommit(
          transferId: transferId,
          destinationPath: publishedPath,
        );
      } catch (error) {
        debugPrint(
          '[File Transfer] Published $transferId but confirmation is pending: $error',
        );
      }
    } catch (error) {
      try {
        await client.failFileCommit(
          transferId: transferId,
          failureReason: error.toString().toLowerCase().contains('hash')
              ? 'HashMismatch'
              : 'PolicyDenied',
          message: JsonRpcRiftClient.formatDisplayError(error),
        );
      } catch (reportError) {
        debugPrint(
          '[File Transfer] Failed to report publication failure for $transferId: $reportError',
        );
      }
      _maybeNotifyWithRoute(
        title: 'File save failed',
        body:
            '${commit['fileName']?.toString() ?? 'File'} could not be published: ${JsonRpcRiftClient.formatDisplayError(error)}',
        route: NotificationRoute.historyTransferActivity,
      );
    } finally {
      _publishingTransferIds.remove(transferId);
    }
  }

  Future<_IncomingFileDestination?> _prepareIncomingFileDestination(
    String fileName,
  ) async {
    if (Platform.isAndroid) {
      final prepared = await AndroidShell.prepareIncomingDownload(fileName);
      final stagingPath = prepared?['stagingPath']?.toString();
      final displayPath = prepared?['displayPath']?.toString();
      if (stagingPath == null ||
          stagingPath.isEmpty ||
          displayPath == null ||
          displayPath.isEmpty) {
        return null;
      }
      return _IncomingFileDestination(
        transferPath: stagingPath,
        displayPath: displayPath,
      );
    }

    final destinationPath = await buildIncomingFilePath(fileName);
    if (destinationPath == null || destinationPath.isEmpty) {
      return null;
    }
    return _IncomingFileDestination(
      transferPath: destinationPath,
      displayPath: destinationPath,
    );
  }

  Future<void> _handleCompletedFileTransfer(
    Map<String, dynamic> event,
  ) async {
    final fileName = event['fileName']?.toString() ?? 'file';
    final mediaType =
        event['mediaType']?.toString() ?? 'application/octet-stream';
    final peer = event['peerDeviceId']?.toString() ?? 'trusted device';
    final daemonDestinationPath = event['destinationPath']?.toString();
    final isIncoming = daemonDestinationPath != null &&
        daemonDestinationPath.trim().isNotEmpty;
    var displayDestinationPath = daemonDestinationPath;
    var openDestinationPath = daemonDestinationPath;

    if (Platform.isAndroid && isIncoming) {
      try {
        final published = await AndroidShell.publishIncomingDownload(
          stagingPath: daemonDestinationPath,
          fileName: fileName,
          mediaType: mediaType,
        );
        displayDestinationPath = published?['displayPath']?.toString();
        openDestinationPath = published?['contentUri']?.toString();
        if (displayDestinationPath == null ||
            displayDestinationPath.isEmpty ||
            openDestinationPath == null ||
            openDestinationPath.isEmpty) {
          throw const FileSystemException(
            'Android did not return the published download location.',
          );
        }
      } catch (error) {
        _maybeNotifyWithRoute(
          title: 'File save failed',
          body:
              '$fileName was received but could not be added to Downloads: $error',
          route: NotificationRoute.historyTransferActivity,
        );
        return;
      }
    }

    final body =
        displayDestinationPath == null || displayDestinationPath.trim().isEmpty
            ? '$fileName ${isIncoming ? 'received from' : 'sent to'} $peer.'
            : '$fileName saved to $displayDestinationPath.';
    if (!Platform.isIOS) {
      _maybeNotify(isIncoming ? 'File received' : 'File sent', body);
    }
    _maybeNotifyCompletedTransfer(
      title: isIncoming ? 'File received' : 'File sent',
      body: body,
      destinationPath: openDestinationPath,
    );
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
      final destination = await _prepareIncomingFileDestination(fileName);
      if (destination == null) {
        throw const FileSystemException(
          'Could not prepare the Downloads save location.',
        );
      }

      final shouldAccept = await _confirmIncomingFileOffer(
        fileName: fileName,
        sourceDeviceId: sourceDeviceId,
        destinationPath: destination.displayPath,
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
            'Saved to: ${destination.displayPath}',
          ),
        ),
      );
      _maybeNotify(
          'Incoming file', 'Receiving $fileName from $sourceDeviceId.');

      await client.acceptFileOffer(
        transferId: transferId,
        destinationPath: destination.transferPath,
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
      theme: buildRiftTheme(),
      home: widget.hasCompletedOnboarding
          ? rift_ui.AppShell(
              key: _appShellKey,
              historyRouteNotifier: _historyRouteNotifier,
              sharedClipboardTextNotifier: _sharedClipboardTextNotifier,
            )
          : const OnboardingScreen(),
    );
  }
}

class _IncomingFileDestination {
  const _IncomingFileDestination({
    required this.transferPath,
    required this.displayPath,
  });

  final String transferPath;
  final String displayPath;
}
