import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/rift_exceptions.dart';
import '../core/rift_log.dart';
import '../interfaces/trust_store.dart';
import '../network/session_manager.dart';
import '../operation/operation_manager.dart';
import '../operation/operation_models.dart';
import 'file_transfer_models.dart';

class FileTransferService {
  static const String requiredCapability = 'file.transfer';
  static const int defaultChunkSize = 256 * 1024;
  static const int maxChunkSize = 4 * 1024 * 1024;
  static const int defaultOfferExpiryMs = 300000;

  final SessionManager _sessionManager;
  final TrustStore _trustStore;
  final OperationManager _operationManager;
  final String _localDeviceId;
  final String _storagePath;

  final Map<String, _RemoteFileOfferState> _remoteOffers = {};
  final Map<String, _OutgoingTransferState> _outgoingTransfers = {};
  final Map<String, _IncomingTransferState> _incomingTransfers = {};

  late final StreamSubscription<ProtocolMessage> _messageSub;

  final _fileOfferController = StreamController<Map<String, dynamic>>.broadcast();
  final _progressController = StreamController<Map<String, dynamic>>.broadcast();
  final _completedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _failedController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onFileOffer => _fileOfferController.stream;
  Stream<Map<String, dynamic>> get onTransferProgress =>
      _progressController.stream;
  Stream<Map<String, dynamic>> get onTransferCompleted =>
      _completedController.stream;
  Stream<Map<String, dynamic>> get onTransferFailed => _failedController.stream;

  FileTransferService({
    required SessionManager sessionManager,
    required TrustStore trustStore,
    required OperationManager operationManager,
    required String localDeviceId,
    required String storagePath,
  })  : _sessionManager = sessionManager,
        _trustStore = trustStore,
        _operationManager = operationManager,
        _localDeviceId = localDeviceId,
        _storagePath = storagePath {
    _messageSub = _sessionManager.onMessage.listen(_handleMessage);
  }

  Future<void> dispose() async {
    await _messageSub.cancel();
    await _fileOfferController.close();
    await _progressController.close();
    await _completedController.close();
    await _failedController.close();
  }

  Future<OfferFileResult> offerFile({
    required String targetDeviceId,
    required String localPath,
    String? fileName,
    String? mediaType,
  }) async {
    if (targetDeviceId.trim().isEmpty) {
      throw const RiftNotFoundException('A target device is required.');
    }

    final file = File(localPath);
    if (!await file.exists()) {
      throw RiftNotFoundException("Local file '$localPath' was not found.");
    }

    await _ensurePeerCanUseFileTransfer(targetDeviceId);

    final resolvedFileName = (fileName == null || fileName.trim().isEmpty)
        ? p.basename(localPath)
        : fileName.trim();
    if (resolvedFileName.isEmpty) {
      throw const RiftException(-32001, 'A file name is required.');
    }

    final resolvedMediaType = (mediaType == null || mediaType.trim().isEmpty)
        ? 'application/octet-stream'
        : mediaType.trim();

    final byteSize = await file.length();
    if (byteSize < 0) {
      throw const RiftException(-32001, 'Invalid file size.');
    }

    final wholeFileHash = await _computeFileSha256(file);
    final transferId = const Uuid().v4();
    final operationId = const Uuid().v4();
    final chunkCount = _computeChunkCount(byteSize, defaultChunkSize);

    _operationManager.createOperation(
      operationId: operationId,
      operationType: 'file.send',
      sourceDeviceId: _localDeviceId,
      destinationDeviceId: targetDeviceId,
    );
    _operationManager.transitionOperation(
      operationId,
      OperationState.pending,
      details: {
        'transferId': transferId,
        'fileName': resolvedFileName,
        'byteSize': byteSize,
      },
    );

    final transfer = _OutgoingTransferState(
      transferId: transferId,
      operationId: operationId,
      targetDeviceId: targetDeviceId,
      localPath: localPath,
      fileName: resolvedFileName,
      mediaType: resolvedMediaType,
      byteSize: byteSize,
      sha256: wholeFileHash,
      chunkSize: defaultChunkSize,
      chunkCount: chunkCount,
      expiresAt: DateTime.now()
          .toUtc()
          .add(const Duration(milliseconds: defaultOfferExpiryMs)),
      state: 'pending',
    );
    _outgoingTransfers[transferId] = transfer;

    await _sessionManager.sendMessage(targetDeviceId, {
      'rift': '0.1-draft',
      'messageId': const Uuid().v4(),
      'type': 'file.offer',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': targetDeviceId,
      'payload': {
        'transferId': transferId,
        'fileName': resolvedFileName,
        'mediaType': resolvedMediaType,
        'byteSize': byteSize,
        'sha256': wholeFileHash,
        'chunkSize': defaultChunkSize,
        'chunkCount': chunkCount,
        'expiresInMs': defaultOfferExpiryMs,
        'sourceDeviceId': _localDeviceId,
        'requiredCapability': requiredCapability,
      },
    });

    transfer.state = 'dispatched';
    _operationManager.transitionOperation(operationId, OperationState.dispatched);
    return OfferFileResult(
      transferId: transferId,
      operationId: operationId,
      targetDeviceId: targetDeviceId,
      fileName: resolvedFileName,
      byteSize: byteSize,
      chunkSize: defaultChunkSize,
      chunkCount: chunkCount,
    );
  }

  List<Map<String, dynamic>> listIncomingFileOffers() {
    _pruneExpiredOffers();
    final offers = _remoteOffers.values.toList(growable: false)
      ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
    return offers.map((offer) => offer.toInfo().toJson()).toList(growable: false);
  }

  Future<AcceptFileOfferResult> acceptFileOffer({
    required String transferId,
    required String destinationPath,
    bool overwrite = false,
  }) async {
    _pruneExpiredOffers();

    final offer = _remoteOffers[transferId];
    if (offer == null) {
      throw RiftNotFoundException("Incoming file offer '$transferId' was not found.");
    }

    await _ensurePeerCanUseFileTransfer(offer.sourceDeviceId);

    if (destinationPath.trim().isEmpty) {
      throw const RiftException(
        -32010,
        'A destination path is required to accept a file.',
      );
    }

    final fullDestinationPath = p.normalize(p.absolute(destinationPath));
    final destinationDirectory = p.dirname(fullDestinationPath);
    if (destinationDirectory.isEmpty || destinationDirectory == fullDestinationPath) {
      throw const RiftException(
        -32001,
        'Destination path must include a parent directory.',
      );
    }

    await Directory(destinationDirectory).create(recursive: true);
    if (!overwrite && await File(fullDestinationPath).exists()) {
      throw RiftException(
        -32010,
        "Destination file '$fullDestinationPath' already exists.",
      );
    }

    final stagingDirectory =
        Directory(p.join(_storagePath, 'file-transfer', transferId));
    await stagingDirectory.create(recursive: true);
    final stagingPath = p.join(stagingDirectory.path, '${offer.fileName}.part');
    final stagingFile = File(stagingPath);
    if (await stagingFile.exists()) {
      await stagingFile.delete();
    }

    final operationId = const Uuid().v4();
    _operationManager.createOperation(
      operationId: operationId,
      operationType: 'file.receive',
      sourceDeviceId: offer.sourceDeviceId,
      destinationDeviceId: _localDeviceId,
    );
    _operationManager.transitionOperation(
      operationId,
      OperationState.pending,
      details: {
        'transferId': transferId,
        'fileName': offer.fileName,
        'byteSize': offer.byteSize,
      },
    );
    _operationManager.transitionOperation(operationId, OperationState.dispatched);

    final transfer = _IncomingTransferState(
      transferId: transferId,
      operationId: operationId,
      sourceDeviceId: offer.sourceDeviceId,
      fileName: offer.fileName,
      mediaType: offer.mediaType,
      byteSize: offer.byteSize,
      expectedSha256: offer.sha256,
      chunkSize: offer.chunkSize,
      expectedChunkCount: offer.chunkCount,
      destinationPath: fullDestinationPath,
      stagingDirectory: stagingDirectory.path,
      stagingPath: stagingPath,
      overwrite: overwrite,
      state: 'dispatched',
    );
    _incomingTransfers[transferId] = transfer;

    await _sessionManager.sendMessage(offer.sourceDeviceId, {
      'rift': '0.1-draft',
      'messageId': const Uuid().v4(),
      'type': 'file.accept',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': offer.sourceDeviceId,
      'payload': {
        'transferId': transferId,
        'receivingDeviceId': _localDeviceId,
        'chunkSize': offer.chunkSize,
      },
    });

    _emitProgress(transfer.toInfo());

    return AcceptFileOfferResult(
      transferId: transferId,
      operationId: operationId,
      destinationPath: fullDestinationPath,
    );
  }

  Future<RejectFileOfferResult> rejectFileOffer({
    required String transferId,
    required String failureReason,
    String? message,
  }) async {
    _pruneExpiredOffers();

    final offer = _remoteOffers.remove(transferId);
    if (offer == null) {
      throw RiftNotFoundException("Incoming file offer '$transferId' was not found.");
    }

    await _ensurePeerCanUseFileTransfer(offer.sourceDeviceId);

    await _sessionManager.sendMessage(offer.sourceDeviceId, {
      'rift': '0.1-draft',
      'messageId': const Uuid().v4(),
      'type': 'file.reject',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': offer.sourceDeviceId,
      'payload': {
        'transferId': transferId,
        'failureReason': failureReason,
        if (message != null && message.isNotEmpty) 'message': message,
      },
    });

    return RejectFileOfferResult(transferId: transferId, rejected: true);
  }

  List<Map<String, dynamic>> listFileTransfers() {
    final transfers = <FileTransferInfo>[
      ..._outgoingTransfers.values.map((transfer) => transfer.toInfo()),
      ..._incomingTransfers.values.map((transfer) => transfer.toInfo()),
    ]..sort((a, b) => b.transferId.compareTo(a.transferId));
    return transfers.map((transfer) => transfer.toJson()).toList(growable: false);
  }

  Future<void> _handleMessage(ProtocolMessage msg) async {
    final type = msg.payload['type'] as String?;
    if (type == null || !type.startsWith('file.')) {
      return;
    }

    try {
      _sessionManager.requireCapability(msg.peerDeviceId, requiredCapability);
    } catch (error) {
      RiftLog.warn('[FileTransfer] Dropping $type from ${msg.peerDeviceId}: $error');
      return;
    }

    final payload = msg.payload['payload'] as Map<String, dynamic>?;
    if (payload == null) {
      RiftLog.warn('[FileTransfer] Missing payload for $type from ${msg.peerDeviceId}');
      return;
    }

    try {
      switch (type) {
        case 'file.offer':
          await _handleOffer(msg.peerDeviceId, payload);
          break;
        case 'file.accept':
          await _handleAccept(msg.peerDeviceId, payload);
          break;
        case 'file.reject':
          await _handleReject(msg.peerDeviceId, payload);
          break;
        case 'file.chunk':
          await _handleChunk(msg.peerDeviceId, payload);
          break;
        case 'file.complete':
          await _handleComplete(msg.peerDeviceId, payload);
          break;
        case 'file.cancel':
          await _handleCancel(msg.peerDeviceId, payload);
          break;
        default:
          RiftLog.warn('[FileTransfer] Unknown file message type: $type');
      }
    } catch (error, stackTrace) {
      RiftLog.error(
        '[FileTransfer] Error handling $type',
        error: error,
        stackTrace: stackTrace,
      );
      final transferId = payload['transferId'] as String?;
      if (transferId != null) {
        await _trySendCancel(
          msg.peerDeviceId,
          transferId,
          _failureReasonForError(error),
          error.toString(),
        );
      }
    }
  }

  Future<void> _handleOffer(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final sourceDeviceId = payload['sourceDeviceId'] as String?;
    if (sourceDeviceId == null || sourceDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'file.offer sourceDeviceId mismatch with authenticated peer identity.',
      );
    }

    final transferId = payload['transferId'] as String? ?? '';
    final fileName = payload['fileName'] as String? ?? '';
    final mediaType =
        payload['mediaType'] as String? ?? 'application/octet-stream';
    final byteSize = payload['byteSize'] as int? ?? -1;
    final sha256 = payload['sha256'] as String? ?? '';
    final chunkSize = _normalizeChunkSize(payload['chunkSize'] as int?);
    final chunkCount = payload['chunkCount'] as int? ?? 0;
    final expiresInMs = payload['expiresInMs'] as int? ?? defaultOfferExpiryMs;
    final required = payload['requiredCapability'] as String? ?? '';

    if (transferId.isEmpty ||
        fileName.isEmpty ||
        byteSize < 0 ||
        sha256.isEmpty ||
        chunkCount < 0 ||
        required != requiredCapability) {
      throw const RiftException(-32001, 'Malformed file.offer payload.');
    }

    await _ensurePeerCanUseFileTransfer(peerDeviceId);

    final offer = _RemoteFileOfferState(
      transferId: transferId,
      sourceDeviceId: peerDeviceId,
      fileName: fileName,
      mediaType: mediaType,
      byteSize: byteSize,
      sha256: sha256,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      expiresAt:
          DateTime.now().toUtc().add(Duration(milliseconds: expiresInMs)),
    );
    _remoteOffers[transferId] = offer;
    _emitOffer(offer.toInfo());
  }

  Future<void> _handleAccept(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final transferId = payload['transferId'] as String? ?? '';
    final receivingDeviceId = payload['receivingDeviceId'] as String? ?? '';
    if (transferId.isEmpty) {
      throw const RiftException(-32001, 'Missing transferId in file.accept.');
    }
    if (receivingDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'file.accept receivingDeviceId mismatch with authenticated peer identity.',
      );
    }

    final transfer = _outgoingTransfers[transferId];
    if (transfer == null) {
      throw RiftNotFoundException("Outgoing transfer '$transferId' was not found.");
    }
    if (transfer.targetDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'Accept sender did not match offered target device.',
      );
    }

    transfer.state = 'active';
    _operationManager.transitionOperation(transfer.operationId, OperationState.active);
    await _sendOutgoingTransfer(
      transfer,
      requestedChunkSize: payload['chunkSize'] as int?,
    );
  }

  Future<void> _handleReject(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final transferId = payload['transferId'] as String? ?? '';
    final failureReason = payload['failureReason'] as String? ?? 'PolicyDenied';
    final message = payload['message'] as String?;
    final transfer = _outgoingTransfers[transferId];
    if (transfer == null) {
      return;
    }
    if (transfer.targetDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'Reject sender did not match offered target device.',
      );
    }
    await _failOutgoingTransfer(transfer, failureReason, message);
  }

  Future<void> _handleChunk(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final transferId = payload['transferId'] as String? ?? '';
    final chunkIndex = payload['chunkIndex'] as int? ?? -1;
    final offset = payload['offset'] as int? ?? -1;
    final byteSize = payload['byteSize'] as int? ?? -1;
    final chunkSha256 = payload['chunkSha256'] as String? ?? '';
    final contentBase64 = payload['contentBase64'] as String? ?? '';

    final transfer = _incomingTransfers[transferId];
    if (transfer == null) {
      throw RiftNotFoundException("Incoming transfer '$transferId' was not found.");
    }
    if (transfer.sourceDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'Chunk sender did not match accepted file offer source.',
      );
    }
    if (chunkIndex != transfer.nextChunkIndex) {
      throw const RiftException(-32001, 'Unexpected chunk index.');
    }
    if (offset != transfer.bytesTransferred) {
      throw const RiftException(-32001, 'Unexpected chunk offset.');
    }

    late final List<int> chunkBytes;
    try {
      chunkBytes = base64.decode(contentBase64);
    } on FormatException {
      throw const RiftException(-32006, 'Chunk payload was not valid Base64.');
    }

    if (chunkBytes.length != byteSize) {
      throw const RiftException(
        -32006,
        'Chunk byte size did not match the declared size.',
      );
    }

    final actualChunkHash = sha256.convert(chunkBytes).toString();
    if (actualChunkHash != chunkSha256) {
      throw const RiftException(-32006, 'Chunk SHA-256 verification failed.');
    }

    final raf = await File(transfer.stagingPath).open(mode: FileMode.append);
    try {
      await raf.writeFrom(chunkBytes);
    } finally {
      await raf.close();
    }

    transfer.bytesTransferred += chunkBytes.length;
    transfer.nextChunkIndex += 1;
    transfer.state = 'active';
    _emitProgress(transfer.toInfo());
  }

  Future<void> _handleComplete(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final transferId = payload['transferId'] as String? ?? '';
    final byteSize = payload['byteSize'] as int? ?? -1;
    final wholeFileHash = payload['sha256'] as String? ?? '';
    final chunkCount = payload['chunkCount'] as int? ?? -1;
    final transfer = _incomingTransfers[transferId];
    if (transfer == null) {
      throw RiftNotFoundException("Incoming transfer '$transferId' was not found.");
    }
    if (transfer.sourceDeviceId != peerDeviceId) {
      throw const RiftUnauthorizedException(
        'Completion sender did not match accepted file offer source.',
      );
    }
    if (byteSize != transfer.byteSize ||
        wholeFileHash != transfer.expectedSha256 ||
        chunkCount != transfer.expectedChunkCount ||
        transfer.bytesTransferred != transfer.byteSize) {
      throw const RiftException(
        -32006,
        'Transfer completion metadata did not match the received chunks.',
      );
    }

    final stagedHash = await _computeFileSha256(File(transfer.stagingPath));
    if (stagedHash != transfer.expectedSha256) {
      throw const RiftException(
        -32006,
        'Received file failed whole-file SHA-256 verification.',
      );
    }

    final destinationFile = File(transfer.destinationPath);
    if (!transfer.overwrite && await destinationFile.exists()) {
      throw RiftException(
        -32010,
        "Destination file '${transfer.destinationPath}' already exists.",
      );
    }

    await Directory(p.dirname(transfer.destinationPath)).create(recursive: true);
    if (await destinationFile.exists()) {
      await destinationFile.delete();
    }

    final stagedFile = File(transfer.stagingPath);
    try {
      await stagedFile.rename(transfer.destinationPath);
    } on FileSystemException {
      await stagedFile.copy(transfer.destinationPath);
      if (await stagedFile.exists()) {
        await stagedFile.delete();
      }
    }

    transfer.state = 'done';
    _operationManager.transitionOperation(transfer.operationId, OperationState.done);
    _incomingTransfers.remove(transfer.transferId);
    _remoteOffers.remove(transfer.transferId);
    _emitCompleted(transfer.toInfo());
    await _deleteDirectoryIfExists(transfer.stagingDirectory);
  }

  Future<void> _handleCancel(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final transferId = payload['transferId'] as String? ?? '';
    final failureReason =
        payload['failureReason'] as String? ?? 'ConnectionLost';
    final message = payload['message'] as String?;

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null && outgoing.targetDeviceId == peerDeviceId) {
      await _failOutgoingTransfer(outgoing, failureReason, message);
      return;
    }

    final incoming = _incomingTransfers[transferId];
    if (incoming != null && incoming.sourceDeviceId == peerDeviceId) {
      await _failIncomingTransfer(incoming, failureReason, message);
    }
  }

  Future<void> _sendOutgoingTransfer(
    _OutgoingTransferState transfer, {
    int? requestedChunkSize,
  }) async {
    final chunkSize = _normalizeChunkSize(requestedChunkSize) ?? transfer.chunkSize;
    final file = File(transfer.localPath);
    if (!await file.exists()) {
      await _failOutgoingTransfer(transfer, 'NotFound', 'Local file is no longer available.');
      return;
    }

    final raf = await file.open();
    try {
      var offset = 0;
      var chunkIndex = 0;
      while (offset < transfer.byteSize) {
        final remaining = transfer.byteSize - offset;
        final nextChunkSize = remaining < chunkSize ? remaining : chunkSize;
        final bytes = await raf.read(nextChunkSize);
        if (bytes.isEmpty) {
          throw const RiftException(-32000, 'Unexpected end of file while sending transfer.');
        }

        final chunkHash = sha256.convert(bytes).toString();
        final isLastChunk = offset + bytes.length >= transfer.byteSize;
        await _sessionManager.sendMessage(transfer.targetDeviceId, {
          'rift': '0.1-draft',
          'messageId': const Uuid().v4(),
          'type': 'file.chunk',
          'sourceDeviceId': _localDeviceId,
          'destinationDeviceId': transfer.targetDeviceId,
          'payload': {
            'transferId': transfer.transferId,
            'chunkIndex': chunkIndex,
            'offset': offset,
            'byteSize': bytes.length,
            'chunkSha256': chunkHash,
            'contentBase64': base64.encode(bytes),
            'isLastChunk': isLastChunk,
          },
        });

        offset += bytes.length;
        chunkIndex += 1;
        transfer.bytesTransferred = offset;
        transfer.state = 'active';
        _emitProgress(transfer.toInfo());
      }
    } catch (error) {
      await _failOutgoingTransfer(
        transfer,
        _failureReasonForError(error),
        error.toString(),
      );
      rethrow;
    } finally {
      await raf.close();
    }

    await _sessionManager.sendMessage(transfer.targetDeviceId, {
      'rift': '0.1-draft',
      'messageId': const Uuid().v4(),
      'type': 'file.complete',
      'sourceDeviceId': _localDeviceId,
      'destinationDeviceId': transfer.targetDeviceId,
      'payload': {
        'transferId': transfer.transferId,
        'byteSize': transfer.byteSize,
        'sha256': transfer.sha256,
        'chunkCount': transfer.chunkCount,
      },
    });

    transfer.state = 'done';
    _operationManager.transitionOperation(transfer.operationId, OperationState.done);
    _emitCompleted(transfer.toInfo());
  }

  Future<void> _failOutgoingTransfer(
    _OutgoingTransferState transfer,
    String failureReason,
    String? message,
  ) async {
    transfer.state = 'failed';
    transfer.failureReason = failureReason;
    _transitionOperationToFailed(transfer.operationId, failureReason);
    _emitFailed(transfer.toInfo(), message);
  }

  Future<void> _failIncomingTransfer(
    _IncomingTransferState transfer,
    String failureReason,
    String? message,
  ) async {
    transfer.state = 'failed';
    transfer.failureReason = failureReason;
    _transitionOperationToFailed(transfer.operationId, failureReason);
    _emitFailed(transfer.toInfo(), message);
    _incomingTransfers.remove(transfer.transferId);
    _remoteOffers.remove(transfer.transferId);
    await _deleteDirectoryIfExists(transfer.stagingDirectory);
  }

  void _transitionOperationToFailed(String operationId, String failureReason) {
    try {
      final operation = _operationManager.getOperation(operationId);
      final currentState = operation.state;
      if (currentState == OperationState.created) {
        _operationManager.transitionOperation(
          operationId,
          OperationState.failed,
          failureReason: failureReason,
        );
      } else if (currentState == OperationState.pending ||
          currentState == OperationState.dispatched ||
          currentState == OperationState.active) {
        _operationManager.transitionOperation(
          operationId,
          OperationState.failed,
          failureReason: failureReason,
        );
      }
    } on RiftException {
      // Best-effort transition for races and duplicate terminal updates.
    }
  }

  Future<void> _trySendCancel(
    String peerDeviceId,
    String transferId,
    String failureReason,
    String message,
  ) async {
    try {
      await _sessionManager.sendMessage(peerDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'file.cancel',
        'sourceDeviceId': _localDeviceId,
        'destinationDeviceId': peerDeviceId,
        'payload': {
          'transferId': transferId,
          'failureReason': failureReason,
          'message': message,
        },
      });
    } catch (_) {
      // Best-effort peer notification.
    }
  }

  void _pruneExpiredOffers() {
    final now = DateTime.now().toUtc();
    final expiredIds = _remoteOffers.values
        .where((offer) => !offer.expiresAt.isAfter(now))
        .map((offer) => offer.transferId)
        .toList(growable: false);
    for (final transferId in expiredIds) {
      _remoteOffers.remove(transferId);
    }
  }

  Future<void> _ensurePeerCanUseFileTransfer(String peerDeviceId) async {
    final record = await _trustStore.getPeer(peerDeviceId);
    if (record == null || record.state != TrustState.trusted) {
      throw RiftException(-32004, "Peer '$peerDeviceId' is not trusted.");
    }
    _sessionManager.requireCapability(peerDeviceId, requiredCapability);
  }

  int? _normalizeChunkSize(int? chunkSize) {
    if (chunkSize == null || chunkSize <= 0) {
      return defaultChunkSize;
    }
    if (chunkSize > maxChunkSize) {
      return maxChunkSize;
    }
    return chunkSize;
  }

  int _computeChunkCount(int byteSize, int chunkSize) {
    if (byteSize == 0) {
      return 0;
    }
    return ((byteSize + chunkSize) - 1) ~/ chunkSize;
  }

  Future<String> _computeFileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _deleteDirectoryIfExists(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  String _failureReasonForError(Object error) {
    if (error is RiftException) {
      switch (error.code) {
        case -32003:
          return 'CapabilityUnavailable';
        case -32004:
          return 'Unauthorized';
        case -32006:
          return 'HashMismatch';
        case -32009:
          return 'NotFound';
        case -32010:
          return 'PolicyDenied';
        default:
          return 'ConnectionLost';
      }
    }
    if (error is FileSystemException) {
      return 'StorageUnavailable';
    }
    return 'ConnectionLost';
  }

  void _emitOffer(IncomingFileOfferInfo offer) {
    _fileOfferController.add(offer.toJson());
  }

  void _emitProgress(FileTransferInfo info) {
    _progressController.add(info.toJson());
  }

  void _emitCompleted(FileTransferInfo info) {
    _completedController.add(info.toJson());
  }

  void _emitFailed(FileTransferInfo info, String? message) {
    final payload = info.toJson();
    if (message != null && message.isNotEmpty) {
      payload['message'] = message;
    }
    _failedController.add(payload);
  }
}

class _RemoteFileOfferState {
  final String transferId;
  final String sourceDeviceId;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final String sha256;
  final int chunkSize;
  final int chunkCount;
  final DateTime expiresAt;

  const _RemoteFileOfferState({
    required this.transferId,
    required this.sourceDeviceId,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.sha256,
    required this.chunkSize,
    required this.chunkCount,
    required this.expiresAt,
  });

  IncomingFileOfferInfo toInfo() => IncomingFileOfferInfo(
        transferId: transferId,
        sourceDeviceId: sourceDeviceId,
        fileName: fileName,
        mediaType: mediaType,
        byteSize: byteSize,
        sha256: sha256,
        chunkSize: chunkSize,
        chunkCount: chunkCount,
        expiresAt: expiresAt.toIso8601String(),
      );
}

class _OutgoingTransferState {
  final String transferId;
  final String operationId;
  final String targetDeviceId;
  final String localPath;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final String sha256;
  final int chunkSize;
  final int chunkCount;
  final DateTime expiresAt;
  int bytesTransferred;
  String state;
  String? failureReason;

  _OutgoingTransferState({
    required this.transferId,
    required this.operationId,
    required this.targetDeviceId,
    required this.localPath,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.sha256,
    required this.chunkSize,
    required this.chunkCount,
    required this.expiresAt,
    required this.state,
    this.bytesTransferred = 0,
    this.failureReason,
  });

  FileTransferInfo toInfo() => FileTransferInfo(
        transferId: transferId,
        operationId: operationId,
        direction: 'outgoing',
        peerDeviceId: targetDeviceId,
        fileName: fileName,
        mediaType: mediaType,
        byteSize: byteSize,
        bytesTransferred: bytesTransferred,
        state: state,
        failureReason: failureReason,
      );
}

class _IncomingTransferState {
  final String transferId;
  final String operationId;
  final String sourceDeviceId;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final String expectedSha256;
  final int chunkSize;
  final int expectedChunkCount;
  final String destinationPath;
  final String stagingDirectory;
  final String stagingPath;
  final bool overwrite;
  int bytesTransferred;
  int nextChunkIndex;
  String state;
  String? failureReason;

  _IncomingTransferState({
    required this.transferId,
    required this.operationId,
    required this.sourceDeviceId,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.expectedSha256,
    required this.chunkSize,
    required this.expectedChunkCount,
    required this.destinationPath,
    required this.stagingDirectory,
    required this.stagingPath,
    required this.overwrite,
    required this.state,
    this.bytesTransferred = 0,
    this.nextChunkIndex = 0,
    this.failureReason,
  });

  FileTransferInfo toInfo() => FileTransferInfo(
        transferId: transferId,
        operationId: operationId,
        direction: 'incoming',
        peerDeviceId: sourceDeviceId,
        fileName: fileName,
        mediaType: mediaType,
        byteSize: byteSize,
        bytesTransferred: bytesTransferred,
        state: state,
        failureReason: failureReason,
      );
}
