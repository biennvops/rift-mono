import 'dart:async';
import 'package:app_flutter/constants.dart';
import 'package:app_flutter/screens/clipboard_transfer_screen.dart';
import 'package:app_flutter/src/file_transfer/file_transfer_coordinator.dart';
import 'package:app_flutter/src/file_transfer/send_queue_controller.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/notification_route.dart';
import 'package:app_flutter/src/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_utils/fake_transport.dart';

class FakeTransferJsonRpcClient extends JsonRpcRiftClient {
  FakeTransferJsonRpcClient({
    List<Map<String, dynamic>>? transfers,
    List<Map<String, dynamic>>? clipboardOffers,
    List<Map<String, dynamic>>? incomingFileOffers,
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
        incomingFileOffers =
            incomingFileOffers ?? const <Map<String, dynamic>>[],
        queueItems = queueItems ?? <Map<String, dynamic>>[],
        _isConnected = isConnected,
        super(FakeTransport());

  final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionChangedController = StreamController<bool>.broadcast();
  final _fileOfferController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _clipboardOfferController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _clipboardExpiredController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _fileProgressController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _fileCompletedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _fileFailedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> transfers;
  final List<Map<String, dynamic>> clipboardOffers;
  final List<Map<String, dynamic>> incomingFileOffers;
  int listClipboardOffersCallCount = 0;
  final List<Map<String, dynamic>> notifications = <Map<String, dynamic>>[];
  final bool sendQueueSupported;
  final List<Map<String, dynamic>> queueItems;
  final List<Map<String, Object>> clipboardNotifications =
      <Map<String, Object>>[];
  bool failTrustedPeerLoads = false;
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
  final List<Map<String, String>> acceptedOffers = <Map<String, String>>[];
  final List<Map<String, String>> rejectedOffers = <Map<String, String>>[];
  bool _isConnected;

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<Map<String, dynamic>> get onClipboardOffer =>
      _clipboardOfferController.stream;

  @override
  Stream<Map<String, dynamic>> get onClipboardExpired =>
      _clipboardExpiredController.stream;

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
  Stream<Map<String, dynamic>> get onFileOffer => _fileOfferController.stream;

  @override
  Stream<Map<String, dynamic>> get onFileTransferProgress =>
      _fileProgressController.stream;

  @override
  Stream<Map<String, dynamic>> get onFileTransferCompleted =>
      _fileCompletedController.stream;

  @override
  Stream<Map<String, dynamic>> get onFileTransferFailed =>
      _fileFailedController.stream;

  @override
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

  @override
  Future<dynamic> listClipboardOffers() async {
    listClipboardOffersCallCount += 1;
    return {'offers': clipboardOffers};
  }

  @override
  Future<dynamic> getDeviceInfo() async => {
        'deviceId': 'rift-local-device',
        'displayName': 'This Device',
      };

  @override
  Future<dynamic> listIncomingFileOffers() async =>
      {'offers': incomingFileOffers};

  @override
  Future<dynamic> acceptFileOffer({
    required String transferId,
    required String destinationPath,
    bool overwrite = false,
  }) async {
    acceptedOffers.add({
      'transferId': transferId,
      'destinationPath': destinationPath,
    });
    incomingFileOffers
        .removeWhere((offer) => offer['transferId'] == transferId);
    return {'transferId': transferId, 'accepted': true};
  }

  @override
  Future<dynamic> rejectFileOffer({
    required String transferId,
    required String failureReason,
    String? message,
  }) async {
    rejectedOffers.add({
      'transferId': transferId,
      'failureReason': failureReason,
    });
    incomingFileOffers
        .removeWhere((offer) => offer['transferId'] == transferId);
    return {'transferId': transferId, 'rejected': true};
  }

  @override
  Future<dynamic> listNotifications() async => {
        'notifications': notifications,
        'policy': {
          'enabled': true,
          'blacklistedPackages': <String>[],
        },
      };

  @override
  Future<dynamic> listTrustedPeers() async {
    if (failTrustedPeerLoads) {
      throw StateError('Trusted peers are not available yet');
    }
    return {'peers': trustedPeers};
  }

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
    return {
      'transferId': transferId,
      'cancelled': true,
    };
  }

  Future<void> emitConnectionChanged(bool value) async {
    _isConnected = value;
    _connectionChangedController.add(value);
  }

  Future<void> emitTrustChanged(Map<String, dynamic> value) async {
    _trustChangedController.add(value);
  }

  Future<void> emitFileOffer(Map<String, dynamic> value) async {
    _fileOfferController.add(value);
  }

  Future<void> emitFileProgress(Map<String, dynamic> value) async {
    _fileProgressController.add(value);
  }

  Future<void> emitClipboardOffer(Map<String, dynamic> value) async {
    _clipboardOfferController.add(value);
  }

  Future<void> emitClipboardExpired(Map<String, dynamic> value) async {
    _clipboardExpiredController.add(value);
  }
}

void main() {
  Widget buildScreen({
    required bool revealInFolder,
    FakeTransferJsonRpcClient? client,
    Future<List<Map<String, String>>> Function()? pickSendFilesOverride,
    ValueNotifier<String?>? routeNotifier,
    ValueNotifier<String?>? sharedClipboardTextNotifier,
    bool preferDaemonOnlyOverride = true,
    Future<String?> Function(String fileName)?
        buildIncomingDestinationPathOverride,
  }) {
    return MaterialApp(
      home: MultiProvider(
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
        ],
        child: ClipboardTransferScreen(
          revealCompletedTransfersInFolderOverride: revealInFolder,
          pickSendFilesOverride: pickSendFilesOverride,
          routeNotifier: routeNotifier,
          sharedClipboardTextNotifier: sharedClipboardTextNotifier,
          buildIncomingDestinationPathOverride:
              buildIncomingDestinationPathOverride,
        ),
      ),
    );
  }

  testWidgets('incoming file events are confirmed as one batch',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.defaultDownloadPath: '/tmp/rift-batched-incoming-test',
    });
    final client = FakeTransferJsonRpcClient();
    final navigatorKey = GlobalKey<NavigatorState>();
    final appShellKey = GlobalKey<AppShellState>();
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final coordinator = FileTransferCoordinator(
      client: client,
      navigatorKey: navigatorKey,
      appShellKey: appShellKey,
      scaffoldMessengerKey: messengerKey,
      onNotify: (_, __) {},
      onNotifyWithRoute: ({
        required title,
        required body,
        route,
        payload,
        destinationPath,
      }) {},
      buildIncomingFilePathOverride: (fileName, _) async => '/tmp/$fileName',
    )..init();
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    await client.emitFileOffer({
      'transferId': 'batch-1',
      'sourceDeviceId': 'rift-peer-1',
      'fileName': 'one.txt',
    });
    await client.emitFileOffer({
      'transferId': 'batch-2',
      'sourceDeviceId': 'rift-peer-1',
      'fileName': 'two.txt',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(client.acceptedOffers, isEmpty);
    expect(client.rejectedOffers, isEmpty);
    expect(find.text('2 Incoming Files'), findsOneWidget);
    expect(find.text('2 files'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(client.acceptedOffers, hasLength(2));
    expect(
      client.acceptedOffers.map((offer) => offer['transferId']),
      containsAll(['batch-1', 'batch-2']),
    );
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

    expect(find.text('Send Queue'), findsOneWidget);
    expect(find.textContaining('Now sending 1 file(s) to Pixel 9 Pro'),
        findsOneWidget);
    expect(find.text('View Activity'), findsOneWidget);

    await tester.tap(find.text('View Activity'));
    await tester.pumpAndSettle();

    expect(find.text('Transfer Activity'), findsWidgets);
    expect(find.text('deck.pptx'), findsOneWidget);
  });

  testWidgets(
      'Transfer activity and Incoming Offers tabs show badges for total items',
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
        {
          'transferId': 'transfer-6',
          'peerDeviceId': 'rift-peer-1',
          'fileName': 'doc-3.pdf',
          'mediaType': 'application/pdf',
          'byteSize': 100,
          'bytesTransferred': 100,
          'state': 'done',
          'direction': 'incoming',
        },
      ],
      incomingFileOffers: const [
        {
          'offerId': 'offer-1',
          'sourceDeviceId': 'rift-peer-1',
          'fileName': 'incoming-1.png',
          'byteSize': 2048,
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
    expect(find.text('Incoming Offers'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('Incoming Offers accepts and rejects through IPC',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      incomingFileOffers: [
        {
          'transferId': 'incoming-accept',
          'sourceDeviceId': 'rift-peer-1',
          'fileName': 'accept.txt',
          'mediaType': 'text/plain',
          'byteSize': 12,
        },
        {
          'transferId': 'incoming-reject',
          'sourceDeviceId': 'rift-peer-1',
          'fileName': 'reject.txt',
          'mediaType': 'text/plain',
          'byteSize': 8,
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
        buildIncomingDestinationPathOverride: (fileName) async =>
            '/tmp/$fileName',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Incoming Offers'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Accept').first);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(client.acceptedOffers.single['transferId'], 'incoming-accept');
    expect(find.text('accept.txt'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject').first);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(client.rejectedOffers.single['transferId'], 'incoming-reject');
    expect(find.text('No incoming offers'), findsOneWidget);
  });

  testWidgets('History sections stay overflow-free at target UI sizes',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final offers = List<Map<String, dynamic>>.generate(
      6,
      (index) => {
        'transferId': 'compact-offer-$index',
        'sourceDeviceId': 'rift-peer-1',
        'fileName': 'compact-$index.txt',
        'mediaType': 'text/plain',
        'byteSize': 128 + index,
      },
    );

    for (final size in const [
      Size(420, 600),
      Size(800, 600),
      Size(1200, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        buildScreen(
          revealInFolder: true,
          client: FakeTransferJsonRpcClient(incomingFileOffers: offers),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Incoming Offers'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'viewport $size');
      expect(find.text('compact-0.txt'), findsOneWidget);
      expect(find.text('compact-1.txt'), findsOneWidget);
    }
  });

  testWidgets('Transfer Activity refreshes when progress events arrive',
      (WidgetTester tester) async {
    final transfers = <Map<String, dynamic>>[
      {
        'transferId': 'transfer-live',
        'peerDeviceId': 'rift-peer-1',
        'fileName': 'live.bin',
        'mediaType': 'application/octet-stream',
        'byteSize': 100,
        'bytesTransferred': 10,
        'state': 'active',
        'direction': 'outgoing',
      },
    ];
    final client = FakeTransferJsonRpcClient(transfers: transfers);

    await tester.pumpWidget(
      buildScreen(revealInFolder: true, client: client),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer Activity'));
    await tester.pumpAndSettle();
    expect(find.text('ACTIVE'), findsOneWidget);

    transfers.single
      ..['bytesTransferred'] = 100
      ..['state'] = 'done';
    await client.emitFileProgress({'transferId': 'transfer-live'});
    await tester.pumpAndSettle();

    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('ACTIVE'), findsNothing);
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

  testWidgets('clipboard draft editor stays hidden until shared text arrives',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildScreen(revealInFolder: true));
    await tester.pumpAndSettle();

    expect(find.text('Text to send'), findsNothing);
    expect(find.text('Shared text'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Send Clipboard Now'), findsNothing);
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

    expect(find.text('ITEMS'), findsOneWidget);
    expect(find.text('TOTAL SIZE'), findsOneWidget);
    expect(find.text('All devices'), findsOneWidget);
    expect(find.text('All types'), findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.text('Encrypted text clip ready to fetch'), findsNothing);
    expect(find.text('Auto-synced'), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('clipboard-offer-offer-remote-1')),
          )
          .height,
      lessThanOrEqualTo(100),
    );
  });

  testWidgets('clipboard offer appears immediately and expires from the UI',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient();
    await tester.pumpWidget(
      buildScreen(revealInFolder: true, client: client),
    );
    await tester.pumpAndSettle();

    await client.emitClipboardOffer({
      'offerId': 'offer-live',
      'sourceDeviceId': 'rift-peer-id-from-offer',
      'contentType': 'image/png',
      'byteSize': 512,
      'expiresInMs': 2000,
    });
    await tester.pump();

    expect(find.byKey(const ValueKey('clipboard-offer-offer-live')),
        findsOneWidget);
    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.textContaining('rift-peer-id-from-offer'), findsNothing);
    expect(find.text('IMAGE'), findsOneWidget);
    expect(find.textContaining(RegExp(r'00:0[12]')), findsOneWidget);

    await client.emitClipboardExpired({'offerId': 'offer-live'});
    await tester.pump();
    expect(
        find.byKey(const ValueKey('clipboard-offer-offer-live')), findsNothing);
  });

  testWidgets('clipboard resolves the device name after reconnecting',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-before-connect',
          'sourceDeviceId': 'rift-peer-1',
          'contentType': 'text/plain',
          'byteSize': 24,
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    )..failTrustedPeerLoads = true;

    await tester.pumpWidget(
      buildScreen(revealInFolder: true, client: client),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loading device…'), findsOneWidget);
    expect(find.text('Trusted Device'), findsNothing);

    client.failTrustedPeerLoads = false;
    await client.emitConnectionChanged(true);
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.text('Loading device…'), findsNothing);
  });

  testWidgets('clipboard list excludes offers from this device',
      (WidgetTester tester) async {
    final client = FakeTransferJsonRpcClient(
      clipboardOffers: const [
        {
          'offerId': 'offer-local',
          'sourceDeviceId': 'rift-local-device',
          'contentType': 'text/plain',
          'byteSize': 12,
          'expiresAt': '2099-01-01T00:00:00Z',
        },
        {
          'offerId': 'offer-peer',
          'sourceDeviceId': 'rift-peer-1',
          'contentType': 'text/plain',
          'byteSize': 24,
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    );

    await tester.pumpWidget(
      buildScreen(revealInFolder: true, client: client),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('clipboard-offer-offer-local')),
        findsNothing);
    expect(find.byKey(const ValueKey('clipboard-offer-offer-peer')),
        findsOneWidget);
  });

  testWidgets('clipboard source filter narrows visible offers',
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
        {
          'offerId': 'offer-remote-2',
          'sourceDeviceId': 'rift-peer-2',
          'contentType': 'image/png',
          'byteSize': 512,
          'sha256': 'def456',
          'expiresAt': '2099-01-02T00:00:00Z',
        },
      ],
    )..trustedPeers = [
        {
          'deviceId': 'rift-peer-1',
          'displayName': 'Pixel 9 Pro',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
        {
          'deviceId': 'rift-peer-2',
          'displayName': 'Linux Desktop',
          'platform': 'linux',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
      ];

    await tester.pumpWidget(
      buildScreen(
        revealInFolder: true,
        client: client,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pixel 9 Pro'), findsWidgets);
    expect(find.text('Linux Desktop'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('clipboard-offer-offer-remote-1')),
        matching: find.byIcon(Icons.smartphone),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('clipboard-offer-offer-remote-2')),
        matching: find.byIcon(Icons.computer),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('All devices'));
    await tester.tap(find.text('All devices'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pumpAndSettle();

    expect(find.text('1 of 2'), findsOneWidget);
  });

  testWidgets('clipboard type filter narrows visible offers',
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
        {
          'offerId': 'offer-remote-2',
          'sourceDeviceId': 'rift-peer-2',
          'contentType': 'image/png',
          'byteSize': 512,
          'sha256': 'def456',
          'expiresAt': '2099-01-02T00:00:00Z',
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

    expect(find.text('All types'), findsOneWidget);
    await tester.tap(find.text('All types'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pumpAndSettle();

    expect(find.text('1 of 2'), findsOneWidget);
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
    final sendButton = find.text('Send to 1 device');
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
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

    final removeButton = find.widgetWithText(OutlinedButton, 'Remove');
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(removeButton);
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
  });

  testWidgets('Send tab represents Android peers with a phone icon',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(420, 600));
    final client = FakeTransferJsonRpcClient()
      ..trustedPeers = List<Map<String, dynamic>>.generate(
        4,
        (index) => {
          'deviceId': 'rift-peer-${index + 1}',
          'displayName': 'Phone ${index + 1}',
          'platform': 'android',
          'trustState': 'trusted',
          'presence': 'online',
          'capabilities': ['file.transfer'],
        },
      );

    await tester.pumpWidget(
      buildScreen(revealInFolder: true, client: client),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send File'));
    await tester.pumpAndSettle();

    expect(find.text('Phone 1'), findsOneWidget);
    expect(find.text('Phone 4'), findsOneWidget);
    expect(find.byIcon(Icons.smartphone), findsNWidgets(4));
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('send-device-chip-Phone 1')),
          )
          .height,
      lessThanOrEqualTo(48),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('send-device-chip-Phone 1')))
          .dy,
      tester
          .getTopLeft(find.byKey(const ValueKey('send-device-chip-Phone 2')))
          .dy,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('send-device-chip-Phone 3')))
          .dy,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('send-device-chip-Phone 1')))
            .dy,
      ),
    );
    expect(find.text('No files staged'), findsNothing);
    expect(find.text('No files staged for sending.'), findsOneWidget);
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
    final cancelButton = find.widgetWithText(OutlinedButton, 'Cancel');
    await tester.drag(find.byType(ListView).first, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(client.removedQueueItems, ['queue-1']);
    expect(find.text('demo-1.txt'), findsNothing);
  });
}
