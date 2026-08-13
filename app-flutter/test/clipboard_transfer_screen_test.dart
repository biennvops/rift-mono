import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rift/screens/clipboard_transfer_screen.dart';
import 'package:rift/src/file_transfer/send_queue_controller.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:rift/src/platform/ios_clipboard.dart';
import 'package:rift/src/platform/notification_route.dart';
import 'package:rift/src/ui/activity_navigation.dart';
import 'package:rift/src/ui/local_events_notifier.dart';

import 'test_utils/fake_transport.dart';

class FakeTransferJsonRpcClient extends JsonRpcRiftClient {
  FakeTransferJsonRpcClient({
    List<Map<String, dynamic>>? transfers,
    List<Map<String, dynamic>>? clipboardOffers,
    this.clipboardFetchResult,
    this.sendQueueSupported = false,
    List<Map<String, dynamic>>? queueItems,
    bool isConnected = true,
  })  : transfers = transfers ??
            const [
              {
                'transferId': 'transfer-1',
                'peerDeviceId': 'rift-peer-1',
                'fileName': 'report.pdf',
                'mediaType': 'application/pdf',
                'byteSize': 1024,
                'bytesTransferred': 1024,
                'state': 'done',
                'direction': 'incoming',
                'destinationPath':
                    '/storage/emulated/0/Download/Rift/report.pdf',
                'sourceDeviceId': 'rift-peer-1',
              },
            ],
        clipboardOffers = clipboardOffers ?? const <Map<String, dynamic>>[],
        queueItems = queueItems ?? <Map<String, dynamic>>[],
        _isConnected = isConnected,
        super(FakeTransport());

  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _fileCompletedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionChangedController = StreamController<bool>.broadcast();
  final _clipboardOfferController =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> transfers;
  final List<Map<String, dynamic>> clipboardOffers;
  final Map<String, dynamic>? clipboardFetchResult;
  final List<Map<String, dynamic>> notifications = <Map<String, dynamic>>[];
  final bool sendQueueSupported;
  final List<Map<String, dynamic>> queueItems;
  final List<Map<String, Object>> clipboardNotifications =
      <Map<String, Object>>[];
  final List<String> fetchedClipboardOfferIds = <String>[];
  List<Map<String, dynamic>> trustedPeers = [
    {
      'deviceId': 'rift-peer-1',
      'displayName': 'Pixel 9 Pro',
      'platform': 'android',
      'trustState': 'trusted',
      'presence': 'online',
      'capabilities': ['file.transfer'],
    },
  ];
  final List<Map<String, String>> offeredFiles = <Map<String, String>>[];
  final List<Object> offerFileFailures = <Object>[];
  final List<Map<String, String>> assignedQueueTargets =
      <Map<String, String>>[];
  final List<String> retriedQueueItems = <String>[];
  final List<String> removedQueueItems = <String>[];
  final List<String> cancelledTransfers = <String>[];
  bool _isConnected;

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<Map<String, dynamic>> get onClipboardOffer =>
      _clipboardOfferController.stream;

  @override
  Stream<Map<String, dynamic>> get onClipboardExpired =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onNotificationPosted =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onNotificationUpdated =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onNotificationRemoved =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onNotificationActionResult =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onFileOffer =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferProgress =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onFileTransferCompleted =>
      _fileCompletedController.stream;

  @override
  Stream<Map<String, dynamic>> get onFileTransferFailed =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

  @override
  Future<dynamic> listClipboardOffers() async => {'offers': clipboardOffers};

  @override
  Future<dynamic> listIncomingFileOffers() async => {'offers': []};

  @override
  Future<dynamic> fetchClipboardContent(String offerId) async {
    fetchedClipboardOfferIds.add(offerId);
    return clipboardFetchResult ??
        {
          'offerId': offerId,
          'contentType': 'text/plain',
          'contentBase64': 'aGVsbG8gZnJvbSBkZXNrdG9w',
          'verified': true,
        };
  }

  @override
  Future<dynamic> listNotifications() async => {
        'notifications': notifications,
        'policy': {
          'enabled': true,
          'mode': 'all',
          'packageNames': <String>[],
        },
      };

  @override
  Future<dynamic> listTrustedPeers() async => {
        'peers': trustedPeers,
      };

  @override
  Future<dynamic> listFileTransfers() async => {'transfers': transfers};

  @override
  Future<dynamic> notifyClipboardChange({
    required String contentType,
    required int byteSize,
    required String sha256,
    required String contentBase64,
  }) async {
    clipboardNotifications.add(<String, Object>{
      'contentType': contentType,
      'byteSize': byteSize,
      'sha256': sha256,
      'contentBase64': contentBase64,
    });
    return const <String, Object>{'ok': true};
  }

  @override
  Future<dynamic> performNotificationAction({
    required String sourceDeviceId,
    required String notificationId,
    required String action,
  }) async {
    return {
      'operationId': 'notification-op-1',
      'notificationId': notificationId,
      'action': action,
      'state': 'Pending',
    };
  }

  @override
  Future<dynamic> offerFile({
    required String targetDeviceId,
    required String localPath,
    String? fileName,
    String? mediaType,
  }) async {
    offeredFiles.add({
      'targetDeviceId': targetDeviceId,
      'localPath': localPath,
      'fileName': fileName ?? '',
      'mediaType': mediaType ?? '',
    });
    if (offerFileFailures.isNotEmpty) {
      throw offerFileFailures.removeAt(0);
    }
    return {
      'transferId': 'transfer-${offeredFiles.length}',
      'operationId': 'operation-${offeredFiles.length}',
    };
  }

  @override
  Future<bool> supportsSendQueue() async => sendQueueSupported;

  @override
  Future<dynamic> listSendQueue() async => {'items': queueItems};

  @override
  Future<dynamic> assignSendQueueTarget({
    required String queueItemId,
    required String targetDeviceId,
  }) async {
    assignedQueueTargets.add({
      'queueItemId': queueItemId,
      'targetDeviceId': targetDeviceId,
    });
    final item =
        queueItems.firstWhere((entry) => entry['queueItemId'] == queueItemId);
    item['targetDeviceId'] = targetDeviceId;
    item['status'] = 'dispatching';
    return item;
  }

  @override
  Future<dynamic> retrySendQueueItem(String queueItemId) async {
    retriedQueueItems.add(queueItemId);
    final item =
        queueItems.firstWhere((entry) => entry['queueItemId'] == queueItemId);
    item['status'] = 'dispatching';
    return item;
  }

  @override
  Future<dynamic> removeSendQueueItem(String queueItemId) async {
    removedQueueItems.add(queueItemId);
    queueItems.removeWhere((entry) => entry['queueItemId'] == queueItemId);
    return {
      'queueItemId': queueItemId,
      'removed': true,
    };
  }

  @override
  Future<dynamic> cancelFileTransfer(String transferId) async {
    cancelledTransfers.add(transferId);
    final transfer = transfers.firstWhere(
      (entry) => entry['transferId'] == transferId,
      orElse: () => <String, dynamic>{},
    );
    if (transfer.isNotEmpty) {
      transfer['state'] = 'failed';
      transfer['failureReason'] = 'Cancelled';
    }
    return {
      'transferId': transferId,
      'cancelled': true,
    };
  }

  Future<void> emitFileCompleted(Map<String, dynamic> value) async {
    _fileCompletedController.add(value);
  }

  Future<void> emitConnectionChanged(bool value) async {
    _isConnected = value;
    _connectionChangedController.add(value);
  }

  Future<void> emitTrustChanged(Map<String, dynamic> value) async {
    _trustChangedController.add(value);
  }

  Future<void> emitClipboardOffer(Map<String, dynamic> value) async {
    _clipboardOfferController.add(value);
  }
}

void main() {
  Widget buildScreen({
    bool? revealInFolder,
    FakeTransferJsonRpcClient? client,
    Future<List<Map<String, String>>> Function()? pickSendFilesOverride,
    ValueNotifier<String?>? routeNotifier,
    ValueNotifier<String?>? sharedClipboardTextNotifier,
    ValueNotifier<ActivityNavigationRequest?>? activityNavigationNotifier,
    bool preferDaemonOnlyOverride = true,
    bool disableAnimations = false,
    bool? exportCompletedTransfersOverride,
    Future<void> Function(String path)? openFileOverride,
    Future<void> Function(String path)? exportFileOverride,
    bool? iosClipboardActionsOverride,
    Future<IOSClipboardContent?> Function()? readClipboardContentOverride,
    Future<String?> Function()? readClipboardTextOverride,
    Future<void> Function(IOSClipboardContent content)?
        writeClipboardContentOverride,
    Future<void> Function(String text)? writeClipboardTextOverride,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: MultiProvider(
          providers: [
            Provider<JsonRpcRiftClient>.value(
              value: client ?? FakeTransferJsonRpcClient(),
            ),
            ChangeNotifierProvider<SendQueueController>(
              create: (context) => SendQueueController(
                context.read<JsonRpcRiftClient>(),
                preferDaemonOnlyOverride,
              ),
            ),
            ChangeNotifierProvider<LocalEventsNotifier>(
              create: (context) =>
                  LocalEventsNotifier(context.read<JsonRpcRiftClient>()),
            ),
          ],
          child: ClipboardTransferScreen(
            revealCompletedTransfersInFolderOverride: revealInFolder,
            exportCompletedTransfersOverride: exportCompletedTransfersOverride,
            openFileOverride: openFileOverride,
            exportFileOverride: exportFileOverride,
            iosClipboardActionsOverride: iosClipboardActionsOverride,
            readClipboardContentOverride: readClipboardContentOverride,
            readClipboardTextOverride: readClipboardTextOverride,
            writeClipboardContentOverride: writeClipboardContentOverride,
            writeClipboardTextOverride: writeClipboardTextOverride,
            pickSendFilesOverride: pickSendFilesOverride,
            routeNotifier: routeNotifier,
            sharedClipboardTextNotifier: sharedClipboardTextNotifier,
            activityNavigationNotifier: activityNavigationNotifier,
          ),
        ),
      ),
    );
  }

  testWidgets('default Activity keeps the Rift four-section UI',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump();

    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Send File'), findsOneWidget);
    expect(find.text('Incoming Offers'), findsOneWidget);
    expect(find.text('Transfer Activity'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
  });

  testWidgets('Activity swipe order follows the visible tab order',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pumpAndSettle();

    final swipeArea = find.byKey(
      const ValueKey('activity-section-swipe-area'),
    );
    const orderedSections = [
      'clipboard',
      'send',
      'incomingOffers',
      'transferActivity',
      'notifications',
    ];

    for (var index = 0; index < orderedSections.length; index++) {
      expect(
        find.byKey(ValueKey('activity-tab-${orderedSections[index]}')),
        findsOneWidget,
      );
      if (index == orderedSections.length - 1) continue;

      await tester.drag(swipeArea, const Offset(-240, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('activity-tab-${orderedSections[index + 1]}')),
        findsOneWidget,
      );
    }

    for (var index = orderedSections.length - 1; index > 0; index--) {
      await tester.drag(swipeArea, const Offset(240, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('activity-tab-${orderedSections[index - 1]}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('Activity reduced motion settles subsection changes immediately',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildScreen(disableAnimations: true));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('activity-tab-send')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('history-section-content-send')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('history-section-content-clipboard')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Activity external route uses the same subsection transition',
      (WidgetTester tester) async {
    final routeNotifier = ValueNotifier<String?>(null);
    await tester.pumpWidget(buildScreen(routeNotifier: routeNotifier));
    await tester.pumpAndSettle();

    routeNotifier.value = NotificationRoute.historyIncomingOffers;
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('history-section-content-incomingOffers')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-tab-incomingOffers')),
      findsOneWidget,
    );
  });
  testWidgets('default Activity remains compact on a phone viewport',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildScreen());
    await tester.pump();

    expect(find.text('Activity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Clipboard shows a newly received offer immediately',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient();
    await tester.pumpWidget(buildScreen(client: client));
    await tester.pumpAndSettle();

    await client.emitClipboardOffer({
      'offerId': 'offer-live',
      'sourceDeviceId': 'rift-peer-1',
      'contentType': 'text/plain',
      'byteSize': 27,
      'sha256': 'hash-live',
      'expiresInMs': 120000,
    });
    await tester.pump();

    expect(find.byKey(const ValueKey('clipboard-offer-offer-live')),
        findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsOneWidget);
    expect(find.text('TEXT'), findsOneWidget);
  });

  testWidgets('Transfer activity hides folder action for direct-open flow',
      (WidgetTester tester) async {
    final routeNotifier =
        ValueNotifier<String?>(NotificationRoute.historyTransferActivity);
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        routeNotifier: routeNotifier,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(
      find.textContaining(
        'Saved to: /storage/emulated/0/Download/Rift/report.pdf',
      ),
      findsOneWidget,
    );
    expect(find.text('Open File'), findsOneWidget);
    expect(find.text('Open Folder'), findsNothing);
  });

  testWidgets('iOS transfer actions preview and export the saved file',
      (WidgetTester tester) async {
    String? openedPath;
    String? exportedPath;
    final routeNotifier =
        ValueNotifier<String?>(NotificationRoute.historyTransferActivity);
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        exportCompletedTransfersOverride: true,
        openFileOverride: (path) async => openedPath = path,
        exportFileOverride: (path) async => exportedPath = path,
        routeNotifier: routeNotifier,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(openedPath, '/storage/emulated/0/Download/Rift/report.pdf');
    expect(exportedPath, '/storage/emulated/0/Download/Rift/report.pdf');
  });

  testWidgets('Transfer activity retains completed event after active refresh',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: const <Map<String, dynamic>>[],
    );
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        client: client,
        routeNotifier:
            ValueNotifier<String?>(NotificationRoute.historyTransferActivity),
      ),
    );
    await tester.pumpAndSettle();

    await client.emitFileCompleted(const {
      'transferId': 'completed-transfer',
      'peerDeviceId': 'rift-peer-1',
      'fileName': 'received.pdf',
      'mediaType': 'application/pdf',
      'byteSize': 2048,
      'bytesTransferred': 2048,
      'state': 'done',
      'direction': 'incoming',
      'destinationPath': '/documents/Downloads/received.pdf',
    });
    await tester.pumpAndSettle();

    expect(find.text('received.pdf'), findsOneWidget);
    expect(
      find.text('Saved to: /documents/Downloads/received.pdf'),
      findsOneWidget,
    );
    expect(find.text('Open File'), findsOneWidget);
  });

  testWidgets('Transfer activity shows folder action for desktop flow',
      (WidgetTester tester) async {
    final routeNotifier =
        ValueNotifier<String?>(NotificationRoute.historyTransferActivity);
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        routeNotifier: routeNotifier,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('Open File'), findsOneWidget);
    expect(find.text('Open Folder'), findsOneWidget);
  });

  testWidgets('Transfer activity labels outgoing transfers with peer context',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: const [
        {
          'transferId': 'transfer-2',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'clip.mp4',
          'mediaType': 'video/mp4',
          'byteSize': 4096,
          'bytesTransferred': 1024,
          'state': 'active',
          'direction': 'outgoing',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
        routeNotifier:
            ValueNotifier<String?>(NotificationRoute.historyTransferActivity),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.textContaining('Sending to Pixel 9 Pro'), findsOneWidget);
  });

  testWidgets('Send tab shows active transfer banner and can jump to activity',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: const [
        {
          'transferId': 'transfer-3',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'deck.pptx',
          'mediaType':
              'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          'byteSize': 8192,
          'bytesTransferred': 2048,
          'state': 'active',
          'direction': 'outgoing',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Now sending 1 file(s) to Pixel 9 Pro'),
        findsOneWidget);
    expect(find.text('View Activity'), findsOneWidget);

    await tester.tap(find.text('View Activity'));
    await tester.pumpAndSettle();

    expect(find.text('Transfer Activity'), findsWidgets);
    expect(find.text('deck.pptx'), findsOneWidget);
  });

  testWidgets('Transfer activity tab shows badge for active outgoing transfers',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: const [
        {
          'transferId': 'transfer-4',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'doc-1.pdf',
          'mediaType': 'application/pdf',
          'byteSize': 100,
          'bytesTransferred': 20,
          'state': 'active',
          'direction': 'outgoing',
        },
        {
          'transferId': 'transfer-5',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'doc-2.pdf',
          'mediaType': 'application/pdf',
          'byteSize': 100,
          'bytesTransferred': 40,
          'state': 'pending',
          'direction': 'outgoing',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Transfer Activity'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('Route notifier can switch History screen sections',
      (WidgetTester tester) async {
    final routeNotifier = ValueNotifier<String?>(null);

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        routeNotifier: routeNotifier,
      ),
    );
    await tester.pumpAndSettle();

    routeNotifier.value = NotificationRoute.historyTransferActivity;
    await tester.pumpAndSettle();
    expect(find.text('Transfer Activity'), findsWidgets);

    routeNotifier.value = NotificationRoute.historyIncomingOffers;
    await tester.pumpAndSettle();
    expect(find.text('Incoming Offers'), findsWidgets);
  });

  testWidgets('targeted clipboard Activity filters by exact device ID',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-first',
          'sourceDeviceId': 'rift-first',
          'contentType': 'text/plain',
          'byteSize': 10,
          'expiresAt': '2099-01-01T00:00:00Z',
        },
        {
          'offerId': 'offer-second',
          'sourceDeviceId': 'rift-second',
          'contentType': 'text/plain',
          'byteSize': 12,
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    )..trustedPeers = [
        {
          'deviceId': 'rift-first',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
        },
        {
          'deviceId': 'rift-second',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
        },
      ];
    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historyClipboard,
        deviceId: 'rift-second',
        displayName: 'Pixel',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            Provider<JsonRpcRiftClient>.value(value: client),
            ChangeNotifierProvider<SendQueueController>(
              create: (_) => SendQueueController(client, false),
            ),
          ],
          child: ClipboardTransferScreen(
            activityNavigationNotifier: navigation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('clipboard-offer-offer-first')),
        findsNothing);
    expect(find.byKey(const ValueKey('clipboard-offer-offer-second')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsOneWidget);

    final targetChip = tester.widget<InputChip>(
      find.byKey(const ValueKey('activity-target-chip')),
    );
    targetChip.onDeleted!.call();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('clipboard-offer-offer-first')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('clipboard-offer-offer-second')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsNothing);
  });
  testWidgets('targeted transfer Activity filters and clears by device ID',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: const [
        {
          'transferId': 'transfer-first',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'first.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'bytesTransferred': 10,
          'state': 'done',
          'direction': 'outgoing',
        },
        {
          'transferId': 'transfer-second',
          'peerDeviceId': 'rift-peer-2',
          'fileName': 'second.txt',
          'mediaType': 'text/plain',
          'byteSize': 12,
          'bytesTransferred': 12,
          'state': 'done',
          'direction': 'outgoing',
        },
      ],
    )..trustedPeers = [
        {
          'deviceId': 'rift-peer-1',
          'displayName': 'Pixel 9 Pro',
          'trustState': 'trusted',
          'presence': 'online',
        },
        {
          'deviceId': 'rift-peer-2',
          'displayName': 'MacBook Pro',
          'trustState': 'trusted',
          'presence': 'online',
        },
      ];
    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historyTransferActivity,
        deviceId: 'rift-peer-2',
        displayName: 'MacBook Pro',
      ),
    );

    await tester.pumpWidget(
      buildScreen(
        client: client,
        activityNavigationNotifier: navigation,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('first.txt'), findsNothing);
    expect(find.text('second.txt'), findsOneWidget);
    final targetChip = tester.widget<InputChip>(
      find.byKey(const ValueKey('activity-target-chip')),
    );
    targetChip.onDeleted!.call();
    await tester.pumpAndSettle();

    expect(find.text('first.txt'), findsOneWidget);
    expect(find.text('second.txt'), findsOneWidget);
    expect(find.text('All devices'), findsOneWidget);
  });

  testWidgets('targeted Send File prefers peer until the user changes it',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-peer-1',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
        {
          'deviceId': 'rift-peer-2',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
      ];
    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historySend,
        deviceId: 'rift-peer-2',
        displayName: 'Pixel',
      ),
    );

    await tester.pumpWidget(
      buildScreen(
        client: client,
        activityNavigationNotifier: navigation,
      ),
    );
    await tester.pumpAndSettle();

    AnimatedContainer chip(String deviceId) => tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('send-device-chip-$deviceId')),
        );
    expect(
        (chip('rift-peer-1').decoration as BoxDecoration).color, Colors.white);
    expect((chip('rift-peer-2').decoration as BoxDecoration).color,
        isNot(Colors.white));

    await tester
        .tap(find.byKey(const ValueKey('send-device-chip-rift-peer-1')));
    await tester
        .tap(find.byKey(const ValueKey('send-device-chip-rift-peer-2')));
    await tester.pump();
    await client.emitTrustChanged(const <String, dynamic>{});
    await tester.pumpAndSettle();

    expect((chip('rift-peer-1').decoration as BoxDecoration).color,
        isNot(Colors.white));
    expect(
        (chip('rift-peer-2').decoration as BoxDecoration).color, Colors.white);
  });

  testWidgets('manual Send target override clears stale preferred target',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient()
      ..trustedPeers = [
        {
          'deviceId': 'rift-peer-a',
          'displayName': 'Pixel A',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
        {
          'deviceId': 'rift-peer-b',
          'displayName': 'Pixel B',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
      ];
    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historySend,
        deviceId: 'rift-peer-a',
        displayName: 'Pixel A',
      ),
    );

    await tester.pumpWidget(
      buildScreen(
        client: client,
        activityNavigationNotifier: navigation,
      ),
    );
    await tester.pumpAndSettle();

    AnimatedContainer chip(String deviceId) => tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('send-device-chip-$deviceId')),
        );
    expect((chip('rift-peer-a').decoration as BoxDecoration).color,
        isNot(Colors.white));
    expect(
        (chip('rift-peer-b').decoration as BoxDecoration).color, Colors.white);

    await tester
        .tap(find.byKey(const ValueKey('send-device-chip-rift-peer-b')));
    await tester
        .tap(find.byKey(const ValueKey('send-device-chip-rift-peer-a')));
    await tester.pumpAndSettle();

    client.trustedPeers = [
      {
        'deviceId': 'rift-peer-b',
        'displayName': 'Pixel B',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['file.transfer'],
      },
    ];
    await client.emitTrustChanged(const <String, dynamic>{});
    await tester.pumpAndSettle();

    expect(
      find.text('Target device is unavailable for file transfer.'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('send-device-chip-rift-peer-a')),
        findsNothing);
    expect((chip('rift-peer-b').decoration as BoxDecoration).color,
        isNot(Colors.white));
  });

  testWidgets('target scope indicator hides on unsupported Activity sections',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historyClipboard,
        deviceId: 'rift-peer-1',
        displayName: 'Pixel 9 Pro',
      ),
    );

    await tester.pumpWidget(
      buildScreen(
        activityNavigationNotifier: navigation,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Activity — Pixel 9 Pro'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsOneWidget);

    await tester.tap(find.text('Incoming Offers'));
    await tester.pumpAndSettle();
    expect(find.text('Activity — Pixel 9 Pro'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsNothing);

    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Activity — Pixel 9 Pro'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsNothing);

    await tester.tap(find.text('Transfer Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity — Pixel 9 Pro'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-target-chip')), findsOneWidget);
  });

  testWidgets('targeted Send File disables sending when its peer disappears',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-targeted',
          'status': 'queued',
          'targetDeviceId': null,
          'localPath': '/tmp/demo-targeted.txt',
          'fileName': 'demo-targeted.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    )..trustedPeers = [
        {
          'deviceId': 'rift-peer-1',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
        {
          'deviceId': 'rift-peer-2',
          'displayName': 'Pixel',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
      ];
    final navigation = ValueNotifier<ActivityNavigationRequest?>(
      const ActivityNavigationRequest(
        route: NotificationRoute.historySend,
        deviceId: 'rift-peer-2',
        displayName: 'Pixel',
      ),
    );

    await tester.pumpWidget(
      buildScreen(
        client: client,
        activityNavigationNotifier: navigation,
      ),
    );
    await tester.pumpAndSettle();

    client.trustedPeers = [
      {
        'deviceId': 'rift-peer-1',
        'displayName': 'Pixel',
        'trustState': 'trusted',
        'presence': 'online',
        'capabilities': ['file.transfer'],
      },
    ];
    await client.emitTrustChanged(const <String, dynamic>{});
    await tester.pumpAndSettle();

    expect(
      find.text('Target device is unavailable for file transfer.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('send-device-chip-rift-peer-1')),
      findsOneWidget,
    );
    final sendButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Select a device'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(sendButton.onPressed, isNull);
  });

  testWidgets('clipboard draft editor stays hidden until shared text arrives',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildScreen(revealInFolder: true));
    await tester.pumpAndSettle();

    expect(find.text('Text to send'), findsNothing);
    expect(find.text('Shared text'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Send Clipboard Now'), findsNothing);
  });

  testWidgets('iOS sends clipboard text after explicit user action',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient();
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        client: client,
        iosClipboardActionsOverride: true,
        readClipboardTextOverride: () async => 'hello from iPhone',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send Clipboard'));
    await tester.pumpAndSettle();

    expect(client.clipboardNotifications, hasLength(1));
    expect(client.clipboardNotifications.single['contentType'], 'text/plain');
    expect(client.clipboardNotifications.single['byteSize'], 17);
    expect(
      client.clipboardNotifications.single['contentBase64'],
      'aGVsbG8gZnJvbSBpUGhvbmU=',
    );
    expect(find.text('Clipboard sent to trusted devices.'), findsOneWidget);
  });

  testWidgets('iOS sends clipboard image after explicit user action',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient();
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        client: client,
        iosClipboardActionsOverride: true,
        readClipboardContentOverride: () async => IOSClipboardContent(
          contentType: 'image/png',
          bytes: Uint8List.fromList(<int>[137, 80, 78, 71]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send Clipboard'));
    await tester.pumpAndSettle();

    expect(client.clipboardNotifications, hasLength(1));
    expect(client.clipboardNotifications.single['contentType'], 'image/png');
    expect(client.clipboardNotifications.single['byteSize'], 4);
    expect(client.clipboardNotifications.single['contentBase64'], 'iVBORw==');
    expect(
      find.text('Clipboard image sent to trusted devices.'),
      findsOneWidget,
    );
  });

  testWidgets('iOS copies incoming clipboard text after explicit user action',
      (WidgetTester tester) async {
    String? copiedText;
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-remote-1',
          'sourceDeviceId': 'rift-peer-1',
          'contentType': 'text/plain',
          'byteSize': 18,
          'sha256': 'abc123',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    );
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        client: client,
        iosClipboardActionsOverride: true,
        writeClipboardTextOverride: (text) async => copiedText = text,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(client.fetchedClipboardOfferIds, ['offer-remote-1']);
    expect(copiedText, 'hello from desktop');
    expect(find.text('Copied to clipboard.'), findsOneWidget);
  });

  testWidgets('iOS copies incoming clipboard image after explicit user action',
      (WidgetTester tester) async {
    IOSClipboardContent? copiedContent;
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-image-1',
          'sourceDeviceId': 'rift-peer-1',
          'contentType': 'image/png',
          'byteSize': 4,
          'sha256': 'abc123',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
      clipboardFetchResult: const {
        'offerId': 'offer-image-1',
        'contentType': 'image/png',
        'contentBase64': 'iVBORw==',
        'verified': true,
      },
    );
    await tester.pumpWidget(
      buildScreen(
        revealInFolder: false,
        client: client,
        iosClipboardActionsOverride: true,
        writeClipboardContentOverride: (content) async {
          copiedContent = content;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy Image'));
    await tester.pumpAndSettle();

    expect(client.fetchedClipboardOfferIds, ['offer-image-1']);
    expect(copiedContent?.contentType, 'image/png');
    expect(copiedContent?.bytes, <int>[137, 80, 78, 71]);
    expect(find.text('Copied to clipboard.'), findsOneWidget);
  });

  testWidgets('clipboard tab shows trusted device clipboard history',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-remote-1',
          'sourceDeviceId': 'rift-peer-1',
          'contentType': 'text/plain',
          'byteSize': 24,
          'sha256': 'abc123',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clipboard History'), findsNothing);
    expect(find.text('Pixel 9 Pro'), findsOneWidget);
    expect(find.textContaining('TEXT'), findsWidgets);
  });

  testWidgets('send flow uses daemon queue actions when supported',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Send Unassigned'));
    await tester.pumpAndSettle();

    expect(client.offeredFiles, isEmpty);
    expect(client.assignedQueueTargets, hasLength(1));
    expect(client.assignedQueueTargets.single['targetDeviceId'], 'rift-peer-1');
  });

  testWidgets(
      'desktop daemon-first reconnect restores visible queue after app opens',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      isConnected: false,
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_peer',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': 'PeerUnreachable',
          'failureMessage': 'offline',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();
    expect(find.text('demo-1.txt'), findsNothing);

    await client.emitConnectionChanged(true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('demo-1.txt'), findsOneWidget);
    expect(find.textContaining('Target: Pixel 9 Pro'), findsOneWidget);
  });

  testWidgets('Clear Sent removes sent daemon-backed queue items',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'sent',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': 'transfer-1',
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();
    expect(find.text('demo-1.txt'), findsOneWidget);

    await tester.tap(find.text('Clear Sent'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(client.removedQueueItems, ['queue-1']);
    expect(find.text('demo-1.txt'), findsNothing);
  });

  testWidgets('Send tab keeps daemon-backed queued files visible without peers',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    )..trustedPeers = const <Map<String, dynamic>>[];

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();

    expect(find.text('demo-1.txt'), findsOneWidget);
    expect(find.text('Add Files'), findsOneWidget);
    expect(
      find.textContaining(
        'No trusted peer currently advertises file.transfer.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'Send tab rebuilds when daemon-backed queue refresh changes peer eligibility',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();

    expect(find.text('Send Unassigned (1)'), findsOneWidget);

    client.queueItems.first['status'] = 'sent';
    await client.emitConnectionChanged(true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Queue Empty'), findsOneWidget);
  });

  testWidgets('Transfer activity cancels an incoming transfer',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      transfers: [
        {
          'transferId': 'incoming-transfer-1',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'large.bin',
          'mediaType': 'application/octet-stream',
          'byteSize': 100,
          'bytesTransferred': 20,
          'state': 'active',
          'direction': 'incoming',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
        routeNotifier:
            ValueNotifier<String?>(NotificationRoute.historyTransferActivity),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(client.cancelledTransfers, ['incoming-transfer-1']);
  });

  testWidgets('Send tab cancels active daemon-backed transfer',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      sendQueueSupported: true,
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'sending',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo-1.txt',
          'fileName': 'demo-1.txt',
          'mediaType': 'text/plain',
          'byteSize': 10,
          'currentOperationId': 'op-1',
          'lastTransferId': 'transfer-1',
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pumpAndSettle();

    expect(client.removedQueueItems, ['queue-1']);
    expect(find.text('demo-1.txt'), findsNothing);
  });
}
