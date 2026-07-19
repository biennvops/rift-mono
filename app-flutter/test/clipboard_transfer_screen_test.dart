import 'dart:async';
import 'package:app_flutter/screens/clipboard_transfer_screen.dart';
import 'package:app_flutter/src/file_transfer/send_queue_controller.dart';
import 'package:app_flutter/src/ipc/json_rpc_client.dart';
import 'package:app_flutter/src/platform/notification_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'test_utils/fake_transport.dart';

class FakeTransferJsonRpcClient extends JsonRpcRiftClient {
  FakeTransferJsonRpcClient({
    List<Map<String, dynamic>>? transfers,
    List<Map<String, dynamic>>? clipboardOffers,
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
  final List<Map<String, dynamic>> transfers;
  final List<Map<String, dynamic>> clipboardOffers;
  final List<Map<String, dynamic>> notifications = <Map<String, dynamic>>[];
  final bool sendQueueSupported;
  final List<Map<String, dynamic>> queueItems;
  final List<Map<String, Object>> clipboardNotifications =
      <Map<String, Object>>[];
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
      const Stream<Map<String, dynamic>>.empty();

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
  Future<dynamic> listNotifications() async => {
        'notifications': notifications,
        'policy': {
          'enabled': true,
          'blacklistedPackages': <String>[],
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
}

void main() {
  Widget buildScreen({
    required bool revealInFolder,
    FakeTransferJsonRpcClient? client,
    Future<List<Map<String, String>>> Function()? pickSendFilesOverride,
    ValueNotifier<String?>? routeNotifier,
    ValueNotifier<String?>? sharedClipboardTextNotifier,
    bool preferDaemonOnlyOverride = true,
    bool? exportCompletedTransfersOverride,
    Future<void> Function(String path)? openFileOverride,
    Future<void> Function(String path)? exportFileOverride,
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
          exportCompletedTransfersOverride: exportCompletedTransfersOverride,
          openFileOverride: openFileOverride,
          exportFileOverride: exportFileOverride,
          pickSendFilesOverride: pickSendFilesOverride,
          routeNotifier: routeNotifier,
          sharedClipboardTextNotifier: sharedClipboardTextNotifier,
        ),
      ),
    );
  }

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

    expect(find.text('Clipboard History'), findsNothing);
    expect(find.text('Pixel 9 Pro'), findsOneWidget);
    expect(find.textContaining('Text'), findsWidgets);
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
