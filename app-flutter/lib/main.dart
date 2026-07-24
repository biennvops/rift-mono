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
import 'screens/pair_device_screen.dart';
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
import 'widgets/rift_snackbar.dart';
import 'widgets/premium_dialog.dart';
import 'src/platform/android_shell.dart';
import 'src/media_playback/android_remote_media_playback_coordinator.dart';
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
  final GlobalKey<AppShellState> _appShellKey = GlobalKey<AppShellState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  StreamSubscription<Map<String, dynamic>>? _pairingCompleteSub;
  StreamSubscription<Map<String, dynamic>>? _trustChangedSub;
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  bool _isResolvingPath = false;
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
  final Set<String> _reservedIncomingPaths = <String>{};
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
  AndroidRemoteMediaPlaybackCoordinator? _androidRemoteMediaPlayback;
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
      _bindMediaPlayback();
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
        await _submitNativeNotificationSyncEvent(
          Map<String, dynamic>.from(arguments),
        );
      }
    }
    return null;
  }

  void _bindMediaPlayback() {
    final client = context.read<JsonRpcRiftClient>();
    if (Platform.isAndroid) {
      _androidRemoteMediaPlayback = AndroidRemoteMediaPlaybackCoordinator(client);
      unawaited(_androidRemoteMediaPlayback!.start());
    }
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

    bool autoAccept = false;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          return PremiumDialog(
            title: 'Incoming File',
            subtitle: 'A trusted peer wants to send you a file.',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // File Name
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.insert_drive_file, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'File',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            fileName,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Sender
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.person, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'From',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            sourceDeviceId,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Destination
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.folder, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Save to',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            destinationPath,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      autoAccept = !autoAccept;
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: autoAccept,
                          onChanged: (val) {
                            setState(() {
                              autoAccept = val == true;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Always auto-accept files from this device',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            cancelText: 'Decline',
            confirmText: 'Accept',
            onCancel: () => Navigator.of(dialogContext).pop(false),
            onConfirm: () async {
              if (autoAccept) {
                final prefs = await SharedPreferences.getInstance();
                final list = prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ?? <String>[];
                if (!list.contains(sourceDeviceId)) {
                  list.add(sourceDeviceId);
                  await prefs.setStringList(AppPrefs.autoAcceptDeviceIds, list);
                }
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(true);
              }
            },
          );
        },
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

  Future<bool> _submitDesktopNotificationAction({
    required String notificationId,
    required String action,
    bool queueIfUnavailable = true,
  }) async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) {
      if (queueIfUnavailable) {
        _queuePendingDesktopNotificationAction(
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
    showDialog<dynamic>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => PairingScreen(
        initialDeviceId: deviceId,
        initialDisplayName: payload['displayName']?.toString(),
        initialPeerFingerprint: payload['fingerprint']?.toString(),
        initialExpiresInMs: (payload['expiresInMs'] as num?)?.toInt(),
        initialCanApproveLocally: true,
        initialStatus: 'Incoming pairing request',
      ),
    )
        .then((result) {
      if (mounted) {
        if (result == 'history') {
          _appShellKey.currentState?.showHistoryRoute(NotificationRoute.historyClipboard);
        } else if (result == 'devices') {
          _appShellKey.currentState?.showRoute(NotificationRoute.devices);
        }
        if (_activePairingDeviceId == deviceId) {
          _activePairingDeviceId = null;
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
    unawaited(_androidRemoteMediaPlayback?.dispose());
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
      try {
        if (Platform.isAndroid) {
          final sourcePlatform = event['sourcePlatform']?.toString();
          if (sourcePlatform != 'windows' &&
              sourcePlatform != 'macos' &&
              sourcePlatform != 'linux') {
            return;
          }
          await AndroidShell.showNotification(
            title: notificationTitle,
            body: notificationBody,
            route: NotificationRoute.historyNotifications,
            payload: mirroredPayload,
          );
          return;
        }
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
    String? destinationPath;
    try {
      // Synchronize path resolution to prevent concurrent duplicate paths
      while (_isResolvingPath) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      _isResolvingPath = true;
      try {
        destinationPath = await buildDefaultIncomingFilePath(
          fileName,
          reservedPaths: _reservedIncomingPaths,
        );
        if (destinationPath != null && destinationPath.isNotEmpty) {
          _reservedIncomingPaths.add(destinationPath);
        }
      } finally {
        _isResolvingPath = false;
      }
      
      if (destinationPath == null || destinationPath.isEmpty) {
        throw const FileSystemException(
          'Could not resolve a public Downloads/Rift save location.',
        );
      }

      bool shouldAccept = false;
      final prefs = await SharedPreferences.getInstance();
      final autoAcceptDevices = prefs.getStringList(AppPrefs.autoAcceptDeviceIds) ?? <String>[];
      
      if (autoAcceptDevices.contains(sourceDeviceId)) {
        shouldAccept = true;
      } else {
        shouldAccept = await _confirmIncomingFileOffer(
          fileName: fileName,
          sourceDeviceId: sourceDeviceId,
          destinationPath: destinationPath,
        ) ?? false;
      }

      if (!shouldAccept) {
        await client.rejectFileOffer(
          transferId: transferId,
          failureReason: 'PolicyDenied',
          message: 'User declined incoming file transfer.',
        );
        final messenger = _scaffoldMessengerKey.currentState;
        if (messenger != null) {
          RiftSnackbar.showWithState(
            messenger: messenger,
            message: 'Declined $fileName from $sourceDeviceId',
            type: RiftSnackbarType.info,
          );
        }
        return;
      }

      final messenger = _scaffoldMessengerKey.currentState;
      if (messenger != null) {
        RiftSnackbar.showWithState(
          messenger: messenger,
          message: 'Receiving $fileName from $sourceDeviceId...\nSaved to: $destinationPath',
          type: RiftSnackbarType.info,
        );
      }
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
      if (destinationPath != null) {
        // We do not remove it immediately because the file needs time to be written by the daemon.
        // It will be cleared when the app restarts, or we can just leave it reserved for the session.
      }
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
          fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: -0.01, height: 40/32),
      headlineMedium: inter.headlineMedium?.copyWith(
          fontSize: 24, fontWeight: FontWeight.w600, height: 32 / 24),
      bodyLarge: inter.bodyLarge?.copyWith(
          fontSize: 18, fontWeight: FontWeight.w400, height: 28 / 18),
      bodyMedium: inter.bodyMedium?.copyWith(
          fontSize: 16, fontWeight: FontWeight.w400, height: 24 / 16),
      bodySmall: inter.bodySmall?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w400, height: 20 / 14),
      labelMedium: inter.labelMedium?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.05, height: 16 / 14),
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
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600);
        }
        return inter.labelSmall!.copyWith(
            color: colorScheme.onSurfaceVariant);
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

class AppShell extends StatefulWidget {
  final ValueNotifier<String?>? historyRouteNotifier;
  final ValueNotifier<String?>? sharedClipboardTextNotifier;

  const AppShell({
    super.key,
    this.historyRouteNotifier,
    this.sharedClipboardTextNotifier,
  });

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  bool _isSidebarCollapsed = false;
  double _sidebarWidth = 280.0;

  late final List<Widget> _screens = [
    const TrustedDevicesScreen(),
    ClipboardTransferScreen(
      routeNotifier: widget.historyRouteNotifier,
      sharedClipboardTextNotifier: widget.sharedClipboardTextNotifier,
    ),
    const SecurityDashboardScreen(),
    const SettingsScreen(),
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

  Widget _buildSidebarItem(BuildContext context, int index, IconData icon, String label) {
    final theme = Theme.of(context);
    final isSelected = _currentIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: InkWell(
        onTap: () {
          setState(() {
            _currentIndex = index;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: _isSidebarCollapsed ? 0 : 16, vertical: 12),
          alignment: _isSidebarCollapsed ? Alignment.center : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0047AB) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: _isSidebarCollapsed ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(
                icon,
                color: isSelected
                    ? const Color(0xFFdae2ff)
                    : const Color(0xFF8899b8),
              ),
              if (!_isSidebarCollapsed) ...[
                const SizedBox(width: 16),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: isSelected
                        ? const Color(0xFFdae2ff)
                        : const Color(0xFF8899b8),
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            // Sidebar
            Container(
              width: _isSidebarCollapsed ? 88 : _sidebarWidth,
              color: const Color(0xFF213145), // inverse-surface
              padding: EdgeInsets.all(_isSidebarCollapsed ? 16 : 24),
              child: Column(
                crossAxisAlignment: _isSidebarCollapsed ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
                children: [
                  // Header
                  InkWell(
                    onTap: () {
                      setState(() {
                        _isSidebarCollapsed = !_isSidebarCollapsed;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisAlignment: _isSidebarCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset('assets/images/rift_logo.png', width: 40, height: 40, fit: BoxFit.cover),
                        ),
                        if (!_isSidebarCollapsed) ...[
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Rift',
                                  style: theme.textTheme.headlineMedium?.copyWith(
                                    color: const Color(0xFFdae2ff), // primary-fixed
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'Secure Sync v0.1',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: const Color(0xFFb1c5ff), // primary-fixed-dim
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Navigation
                  Expanded(
                    child: ListView(
                      children: [
                        _buildSidebarItem(context, 0, Icons.devices, 'Devices'),
                        _buildSidebarItem(context, 1, Icons.history, 'Activity'),
                        _buildSidebarItem(context, 2, Icons.security, 'Security'),
                        _buildSidebarItem(context, 3, Icons.settings, 'Settings'),
                      ],
                    ),
                  ),
                  // CTA
                  FilledButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => const Dialog(
                          backgroundColor: Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          child: PairDeviceScreen(),
                        ),
                      );
                    },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _isSidebarCollapsed 
                        ? const Icon(Icons.add)
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add),
                              SizedBox(width: 8),
                              Text('Add Device'),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            
            // Resizable Handle for Sidebar
            if (!_isSidebarCollapsed)
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (details) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(200.0, 500.0);
                    });
                  },
                  child: Container(
                    width: 8,
                    color: Colors.transparent,
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Main Content
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _screens,
              ),
            ),
          ],
        ),
      );
    }

    // Mobile
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: _screens,
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.08),
          onDestinationSelected: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.devices_outlined, color: theme.colorScheme.outline),
              selectedIcon: Icon(Icons.devices, color: theme.colorScheme.primary),
              label: 'Devices',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined, color: theme.colorScheme.outline),
              selectedIcon: Icon(Icons.history, color: theme.colorScheme.primary),
              label: 'Activity',
            ),
            NavigationDestination(
              icon: Icon(Icons.security_outlined, color: theme.colorScheme.outline),
              selectedIcon: Icon(Icons.security, color: theme.colorScheme.primary),
              label: 'Security',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined, color: theme.colorScheme.outline),
              selectedIcon: Icon(Icons.settings, color: theme.colorScheme.primary),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
