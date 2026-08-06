import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rift/constants.dart';
import 'package:rift/src/file_transfer/send_queue_controller.dart';
import 'package:rift/src/file_transfer/send_queue_entry.dart';
import 'package:rift/src/file_transfer/send_queue_panel.dart';
import 'package:rift/src/ipc/json_rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_utils/fake_transport.dart';

class _FakeQueueClient extends JsonRpcRiftClient {
  _FakeQueueClient({
    this.sendQueueSupported = true,
    List<Map<String, dynamic>>? queueItems,
    this.hideItemsFromList = false,
    this.hideItemsFromGet = false,
    this.listSendQueueCompleter,
  })  : _queueItems = queueItems ?? <Map<String, dynamic>>[],
        super(FakeTransport());

  final bool sendQueueSupported;
  final List<Map<String, dynamic>> _queueItems;
  final bool hideItemsFromList;
  final bool hideItemsFromGet;
  final Completer<void>? listSendQueueCompleter;
  final StreamController<Map<String, dynamic>> _sendQueueChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _sendQueueItemUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> _connectionChangedController =
      StreamController<bool>.broadcast();
  final List<String> cancelledTransfers = <String>[];

  Map<String, dynamic> _findQueueItem(String queueItemId) {
    return _queueItems.firstWhere(
      (item) => item['queueItemId'] == queueItemId,
      orElse: () => throw StateError('Queue item not found: $queueItemId'),
    );
  }

  @override
  bool get isConnected => true;

  @override
  Stream<Map<String, dynamic>> get onSendQueueChanged =>
      _sendQueueChangedController.stream;

  @override
  Stream<Map<String, dynamic>> get onSendQueueItemUpdated =>
      _sendQueueItemUpdatedController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

  @override
  Future<dynamic> listSendQueue() async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    final completer = listSendQueueCompleter;
    if (completer != null && !completer.isCompleted) {
      await completer.future;
    }
    return {
      'items': hideItemsFromList ? <Map<String, dynamic>>[] : _queueItems,
    };
  }

  @override
  Future<dynamic> getSendQueueItem(String queueItemId) async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    if (hideItemsFromGet) {
      throw StateError('Queue item not visible yet');
    }
    return _findQueueItem(queueItemId);
  }

  @override
  Future<dynamic> enqueueFileSend({
    required String localPath,
    String? fileName,
    String? mediaType,
    String? targetDeviceId,
    String? origin,
  }) async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    _queueItems.add({
      'queueItemId': 'queue-${_queueItems.length + 1}',
      'status': targetDeviceId == null ? 'waiting_for_target' : 'queued',
      'targetDeviceId': targetDeviceId,
      'localPath': localPath,
      'fileName': fileName ?? localPath.split(Platform.pathSeparator).last,
      'mediaType': mediaType ?? 'application/octet-stream',
      'byteSize': File(localPath).lengthSync(),
      'currentOperationId': null,
      'lastTransferId': null,
      'failureReason': null,
      'failureMessage': null,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'origin': origin,
    });
    return {
      'queueItemId': 'queue-${_queueItems.length}',
      'status': 'waiting_for_target'
    };
  }

  @override
  Future<dynamic> assignSendQueueTarget({
    required String queueItemId,
    required String targetDeviceId,
  }) async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    final item = _findQueueItem(queueItemId);
    item['targetDeviceId'] = targetDeviceId;
    item['status'] = 'queued';
    item['failureMessage'] = null;
    return item;
  }

  @override
  Future<dynamic> retrySendQueueItem(String queueItemId) async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    final item = _findQueueItem(queueItemId);
    item['status'] =
        item['targetDeviceId'] == null ? 'waiting_for_target' : 'queued';
    item['failureMessage'] = null;
    item['lastTransferId'] = null;
    item['currentOperationId'] = null;
    return item;
  }

  @override
  Future<dynamic> removeSendQueueItem(String queueItemId) async {
    if (!sendQueueSupported) {
      throw Exception('JSON-RPC error -32601: Method not found');
    }
    _queueItems.removeWhere((item) => item['queueItemId'] == queueItemId);
    return {'queueItemId': queueItemId, 'removed': true};
  }

  @override
  Future<dynamic> cancelFileTransfer(String transferId) async {
    cancelledTransfers.add(transferId);
    return {'transferId': transferId, 'cancelled': true};
  }

  void emitSendQueueChanged(Map<String, dynamic> payload) {
    _sendQueueChangedController.add(payload);
  }

  void emitSendQueueItemUpdated(Map<String, dynamic> payload) {
    _sendQueueItemUpdatedController.add(payload);
  }

  void emitConnectionChanged(bool isConnected) {
    _connectionChangedController.add(isConnected);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('controller persists staged queue entries', () async {
    final controller = SendQueueController();
    final entry = SendQueueEntry(
      localPath: '/tmp/demo.txt',
      fileName: 'demo.txt',
      mediaType: 'text/plain',
      byteSize: 5,
    )..targetDeviceId = 'rift-peer-1';
    controller.addAll([entry]);

    await controller.persist();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppPrefs.sendQueueState);
    expect(raw, isNotNull);

    final decoded = jsonDecode(raw!) as List<dynamic>;
    expect(decoded, hasLength(1));
    expect((decoded.first as Map)['fileName'], 'demo.txt');
  });

  test('controller skips legacy restore on daemon-first desktop targets',
      () async {
    SharedPreferences.setMockInitialValues({
      AppPrefs.sendQueueState: jsonEncode([
        {
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'status': 'queued',
        },
      ]),
    });

    final controller = SendQueueController(
      _FakeQueueClient(sendQueueSupported: false),
      true,
    );

    await controller.restore();

    expect(controller.items, isEmpty);
  });

  test('controller skips legacy persistence on daemon-first desktop targets',
      () async {
    final controller = SendQueueController(
      _FakeQueueClient(sendQueueSupported: false),
      true,
    );
    controller.addAll([
      SendQueueEntry(
        localPath: '/tmp/demo.txt',
        fileName: 'demo.txt',
        mediaType: 'text/plain',
        byteSize: 5,
      ),
    ]);

    await controller.persist();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPrefs.sendQueueState), isNull);
  });

  test('controller does not fall back to local enqueue on daemon-first desktop',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('rift-queue-no-local');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final controller = SendQueueController(
      _FakeQueueClient(sendQueueSupported: false),
      true,
    );
    final result = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    expect(result.added, 0);
    expect(result.skipped, 1);
    expect(controller.items, isEmpty);
  });

  test('controller eligibleForPeer keeps peer-scoped semantics', () {
    final controller = SendQueueController();
    final first = SendQueueEntry(
      localPath: '/tmp/one.txt',
      fileName: 'one.txt',
      mediaType: 'text/plain',
      byteSize: 1,
    )..targetDeviceId = 'rift-peer-1';
    final second = SendQueueEntry(
      localPath: '/tmp/two.txt',
      fileName: 'two.txt',
      mediaType: 'text/plain',
      byteSize: 1,
    );
    final third = SendQueueEntry(
      localPath: '/tmp/three.txt',
      fileName: 'three.txt',
      mediaType: 'text/plain',
      byteSize: 1,
    )..targetDeviceId = 'rift-peer-2';

    controller.addAll([first, second, third]);

    final eligible = controller.eligibleForPeer('rift-peer-1');
    expect(eligible.map((item) => item.fileName), ['one.txt', 'two.txt']);
  });

  test('controller enqueueRequests adds valid files and skips duplicates',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('rift-queue-ctrl');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final controller = SendQueueController();
    final first = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);
    final second = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    expect(first.added, 1);
    expect(first.skipped, 0);
    expect(second.added, 0);
    expect(second.skipped, 1);
    expect(controller.items, hasLength(1));
  });

  test('controller prefers daemon-backed queue when supported', () async {
    final tempDir = await Directory.systemTemp.createTemp('rift-queue-daemon');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final client = _FakeQueueClient(sendQueueSupported: true);
    final controller = SendQueueController(client);
    final result = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    expect(result.added, 1);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.fileName, 'demo.txt');
  });

  test('controller hydrates enqueued daemon item when listSendQueue is stale',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('rift-queue-stale');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final client = _FakeQueueClient(
      sendQueueSupported: true,
      hideItemsFromList: true,
    );
    final controller = SendQueueController(client);
    final result = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    expect(result.added, 1);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.queueItemId, 'queue-1');
    expect(controller.items.single.fileName, 'demo.txt');
  });

  test('controller waits for in-flight restore before daemon enqueue',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('rift-queue-race');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final restoreGate = Completer<void>();
    final client = _FakeQueueClient(
      sendQueueSupported: true,
      listSendQueueCompleter: restoreGate,
    );
    final controller = SendQueueController(client);

    final restoreFuture = controller.restore();
    final enqueueFuture = controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    await Future<void>.delayed(Duration.zero);
    expect(controller.items, isEmpty);

    restoreGate.complete();
    final result = await enqueueFuture;
    await restoreFuture;

    expect(result.added, 1);
    expect(result.skipped, 0);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.fileName, 'demo.txt');
  });

  test('controller keeps provisional daemon entry when readback is stale',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('rift-queue-provisional');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final client = _FakeQueueClient(
      sendQueueSupported: true,
      hideItemsFromList: true,
      hideItemsFromGet: true,
    );
    final controller = SendQueueController(client);
    final result = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);

    expect(result.added, 1);
    expect(result.skipped, 0);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.queueItemId, 'queue-1');
    expect(controller.items.single.fileName, 'demo.txt');
    expect(controller.items.single.status, SendQueueStatus.queued);
  });

  test('controller dispatchToPeer keeps provisional daemon item when list is stale',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('rift-queue-dispatch-stale');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final client = _FakeQueueClient(
      sendQueueSupported: true,
      hideItemsFromList: true,
      hideItemsFromGet: true,
    );
    final controller = SendQueueController(client);

    final enqueueResult = await controller.enqueueRequests([
      {
        'localPath': file.path,
        'fileName': 'demo.txt',
        'mediaType': 'text/plain',
      },
    ]);
    expect(enqueueResult.added, 1);
    expect(controller.items, hasLength(1));

    final dispatchResult = await controller.dispatchToPeer('rift-peer-1');

    expect(dispatchResult.submitted, 1);
    expect(dispatchResult.failed, 0);
  });

  test('controller assignTarget updates daemon-backed queue item', () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
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
    final controller = SendQueueController(client);

    await controller.restore();
    await controller.assignTarget(
      controller.items.single,
      targetDeviceId: 'rift-peer-1',
    );

    expect(controller.items, hasLength(1));
    expect(controller.items.single.targetDeviceId, 'rift-peer-1');
    expect(controller.items.single.status, SendQueueStatus.queued);
  });

  test('controller retryItem updates daemon-backed queue item', () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'failed',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'currentOperationId': 'op-1',
          'lastTransferId': 'transfer-1',
          'failureReason': 'PeerUnreachable',
          'failureMessage': 'offline',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );
    final controller = SendQueueController(client);

    await controller.restore();
    await controller.retryItem(controller.items.single);

    expect(controller.items, hasLength(1));
    expect(controller.items.single.status, SendQueueStatus.queued);
    expect(controller.items.single.errorMessage, isNull);
  });

  test('controller removeItem removes daemon-backed queue item', () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
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
    final controller = SendQueueController(client);

    await controller.restore();
    await controller.removeItem(controller.items.single);

    expect(controller.items, isEmpty);
  });

  test('controller retargetForSelection re-enqueues daemon item without target',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('rift-retarget');
    final file = File('${tempDir.path}/demo.txt');
    await file.writeAsString('hello');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'failed',
          'targetDeviceId': 'rift-peer-1',
          'localPath': file.path,
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': 'NotFound',
          'failureMessage': 'peer missing',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
      ],
    );
    final controller = SendQueueController(client);

    await controller.restore();
    await controller.retargetForSelection(controller.items.single);

    expect(controller.items, hasLength(1));
    expect(controller.items.single.targetDeviceId, isNull);
    expect(controller.items.single.status, SendQueueStatus.queued);
  });

  test('controller dispatchToPeer assigns and retries daemon-backed items',
      () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/one.txt',
          'fileName': 'one.txt',
          'mediaType': 'text/plain',
          'byteSize': 3,
          'currentOperationId': null,
          'lastTransferId': null,
          'failureReason': null,
          'failureMessage': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'origin': null,
        },
        {
          'queueItemId': 'queue-2',
          'status': 'failed',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/two.txt',
          'fileName': 'two.txt',
          'mediaType': 'text/plain',
          'byteSize': 3,
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
    final controller = SendQueueController(client);

    await controller.restore();
    final result = await controller.dispatchToPeer('rift-peer-1');

    expect(result.submitted, 2);
    expect(result.failed, 0);
    expect(result.requiresLegacyDispatch, isFalse);
    expect(
        controller.items.every((item) => item.targetDeviceId == 'rift-peer-1'),
        isTrue);
  });

  test('controller refreshes from daemon queue item update notification',
      () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'waiting_for_target',
          'targetDeviceId': null,
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
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
    final controller = SendQueueController(client);

    await controller.restore();
    client._queueItems.first['status'] = 'sent';
    client.emitSendQueueItemUpdated({
      'queueItemId': 'queue-1',
      'status': 'sent',
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.items.single.status, SendQueueStatus.sent);
  });

  test('controller refreshes from daemon queue on reconnect', () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'queued',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
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
    final controller = SendQueueController(client);

    await controller.restore();
    client._queueItems.first['status'] = 'sending';
    client.emitConnectionChanged(true);
    await Future<void>.delayed(Duration.zero);

    expect(controller.items.single.status, SendQueueStatus.sending);
  });

  test('controller restore rerun preserves current daemon-backed queue view',
      () async {
    final client = _FakeQueueClient(
      queueItems: [
        {
          'queueItemId': 'queue-1',
          'status': 'queued',
          'targetDeviceId': 'rift-peer-1',
          'localPath': '/tmp/demo.txt',
          'fileName': 'demo.txt',
          'mediaType': 'text/plain',
          'byteSize': 5,
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
    final controller = SendQueueController(client, true);

    await controller.restore();
    expect(controller.items.single.status, SendQueueStatus.queued);

    client._queueItems.first['status'] = 'sending';
    await controller.restore();

    expect(controller.items.single.status, SendQueueStatus.queued);
  });

  test('controller cancelItem uses transfer cancellation in legacy mode',
      () async {
    final client = _FakeQueueClient(sendQueueSupported: false);
    final controller = SendQueueController(client, false);
    final entry = SendQueueEntry(
      localPath: '/tmp/demo.txt',
      fileName: 'demo.txt',
      mediaType: 'text/plain',
      byteSize: 5,
    )
      ..transferId = 'transfer-1'
      ..status = SendQueueStatus.sending;
    controller.addAll([entry]);

    await controller.cancelItem(entry);

    expect(client.cancelledTransfers, ['transfer-1']);
    expect(controller.items, isEmpty);
  });

  test(
      'controller still allows legacy persistence when daemon-only is disabled',
      () async {
    final controller = SendQueueController(
      _FakeQueueClient(sendQueueSupported: false),
      false,
    );
    controller.addAll([
      SendQueueEntry(
        localPath: '/tmp/demo.txt',
        fileName: 'demo.txt',
        mediaType: 'text/plain',
        byteSize: 5,
      ),
    ]);

    await controller.persist();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPrefs.sendQueueState), isNotNull);
  });
}
