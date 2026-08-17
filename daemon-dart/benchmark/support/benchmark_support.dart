import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';

class TlsLoopback {
  TlsLoopback._({
    required this.sender,
    required this.receiver,
    required this.senderIdentity,
    required this.receiverIdentity,
    required this.temporaryDirectory,
    required this._receiverSubscription,
  });

  final SecureSocket sender;
  final SecureSocket receiver;
  final IdentityManagerImpl senderIdentity;
  final IdentityManagerImpl receiverIdentity;
  final Directory temporaryDirectory;
  final StreamSubscription<Uint8List> _receiverSubscription;
  final List<_ReceiveWaiter> _waiters = [];
  Object? _receiveError;
  int receivedBytes = 0;
  int receivedChunks = 0;
  int receiveChecksum = 0;

  static Future<TlsLoopback> open() async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'rift_benchmark_tls_',
    );
    final senderDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}sender',
    );
    final receiverDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}receiver',
    );
    await Future.wait([senderDirectory.create(), receiverDirectory.create()]);

    final senderIdentity = IdentityManagerImpl(senderDirectory.path);
    final receiverIdentity = IdentityManagerImpl(receiverDirectory.path);
    await Future.wait([
      senderIdentity.initialize(),
      receiverIdentity.initialize(),
    ]);

    final serverContext = SecurityContext()
      ..useCertificateChainBytes(
        utf8.encode(receiverIdentity.tlsCertificatePem),
      )
      ..usePrivateKeyBytes(utf8.encode(receiverIdentity.tlsPrivateKeyPem));
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
      requestClientCertificate: false,
      requireClientCertificate: false,
    );
    final accepted = Completer<SecureSocket>();
    final serverSubscription = server.listen(
      accepted.complete,
      onError: accepted.completeError,
    );

    final clientContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(senderIdentity.tlsCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(senderIdentity.tlsPrivateKeyPem));
    final sender = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
      context: clientContext,
      onBadCertificate: (_) => true,
    );
    final receiver = await accepted.future;
    await serverSubscription.cancel();
    await server.close();

    late final TlsLoopback loopback;
    final receiverSubscription = receiver.listen(
      (chunk) => loopback._recordReceived(chunk),
      onError: (Object error, StackTrace stackTrace) {
        loopback._recordReceiveError(error, stackTrace);
      },
      cancelOnError: true,
    );
    loopback = TlsLoopback._(
      sender: sender,
      receiver: receiver,
      senderIdentity: senderIdentity,
      receiverIdentity: receiverIdentity,
      temporaryDirectory: temporaryDirectory,
      receiverSubscription: receiverSubscription,
    );
    return loopback;
  }

  Future<void> waitForReceived(int targetBytes) {
    if (_receiveError != null) {
      return Future<void>.error(_receiveError!);
    }
    if (receivedBytes >= targetBytes) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add(_ReceiveWaiter(targetBytes, completer));
    return completer.future;
  }

  void _recordReceived(Uint8List chunk) {
    receivedBytes += chunk.length;
    receivedChunks++;
    if (chunk.isNotEmpty) {
      receiveChecksum =
          (receiveChecksum + chunk.first + chunk.last + chunk.length) &
          0x7fffffff;
    }
    for (final waiter in List<_ReceiveWaiter>.of(_waiters)) {
      if (receivedBytes >= waiter.targetBytes) {
        _waiters.remove(waiter);
        waiter.completer.complete();
      }
    }
  }

  void _recordReceiveError(Object error, StackTrace stackTrace) {
    _receiveError = error;
    for (final waiter in _waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error, stackTrace);
      }
    }
    _waiters.clear();
  }

  Future<void> close() async {
    for (final waiter in _waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          StateError('TLS loopback closed before the receive target was met.'),
        );
      }
    }
    _waiters.clear();
    sender.destroy();
    receiver.destroy();
    await _receiverSubscription.cancel();
    await Future.wait([senderIdentity.dispose(), receiverIdentity.dispose()]);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

class _ReceiveWaiter {
  const _ReceiveWaiter(this.targetBytes, this.completer);

  final int targetBytes;
  final Completer<void> completer;
}

Uint8List deterministicBytes(int length, {int seed = 0x52494654}) {
  final bytes = Uint8List(length);
  var state = seed & 0xffffffff;
  for (var i = 0; i < bytes.length; i++) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >>> 17;
    state ^= (state << 5) & 0xffffffff;
    state &= 0xffffffff;
    bytes[i] = state & 0xff;
  }
  return bytes;
}

Future<File> createDeterministicFile(
  Directory directory,
  String name,
  int length,
) async {
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  final output = await file.open(mode: FileMode.write);
  try {
    const blockSize = 1024 * 1024;
    final block = deterministicBytes(math.min(blockSize, math.max(1, length)));
    var remaining = length;
    while (remaining > 0) {
      final count = math.min(remaining, block.length);
      await output.writeFrom(block, 0, count);
      remaining -= count;
    }
  } finally {
    await output.close();
  }
  return file;
}

Uint8List jsonPayloadOfSize(int targetBytes) {
  if (targetBytes < 16) {
    throw ArgumentError.value(
      targetBytes,
      'targetBytes',
      'must be at least 16',
    );
  }
  var dataLength = math.max(0, targetBytes - 32);
  while (true) {
    final encoded = Uint8List.fromList(
      utf8.encode(
        json.encode({'type': 'benchmark.control', 'data': 'x' * dataLength}),
      ),
    );
    final difference = targetBytes - encoded.length;
    if (difference == 0) return encoded;
    dataLength += difference;
    if (dataLength < 0) {
      throw StateError(
        'Could not construct a JSON payload of $targetBytes bytes.',
      );
    }
  }
}

Map<String, dynamic> chunkEnvelope({
  required List<int> rawBytes,
  required String chunkSha256,
  required int chunkIndex,
  required int offset,
  required bool isLastChunk,
  String? contentBase64,
}) => {
  'rift': '0.1-draft',
  'messageId':
      '00000000-0000-4000-8000-${chunkIndex.toString().padLeft(12, '0')}',
  'type': 'file.chunk',
  'sourceDeviceId': 'rift-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'destinationDeviceId': 'rift-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'payload': {
    'transferId': '11111111-1111-4111-8111-111111111111',
    'chunkIndex': chunkIndex,
    'offset': offset,
    'byteSize': rawBytes.length,
    'chunkSha256': chunkSha256,
    'contentBase64': contentBase64 ?? base64.encode(rawBytes),
    'isLastChunk': isLastChunk,
  },
};
