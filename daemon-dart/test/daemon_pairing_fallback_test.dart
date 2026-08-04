import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';

void main() {
  test('pairing session reuse requires an active transport socket', () {
    final context = SessionContext(
      peerDeviceId: 'rift-test-peer',
      isInitiator: true,
    );

    expect(RiftDaemon.hasActivePairingSession(context, null), isFalse);
    expect(
      RiftDaemon.hasActivePairingSession(
        context,
        const PeerSocketEndpoint(address: '192.168.1.2', port: 9140),
      ),
      isTrue,
    );
  });

  test(
    'RiftDaemon openSessionForPairing falls back to trustedEndpoints if discovery is empty',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'rift_daemon_test_',
      );
      try {
        // 1. Pre-populate the trust store with a peer containing a trusted endpoint
        final trustStore = TrustStoreImpl(
          p.join(tempDir.path, 'trust_store.db'),
        );
        await trustStore.initialize();
        await trustStore.upsertPeer(
          PeerRecord(
            deviceId: 'rift-test-peer',
            certDer: Uint8List(0), // Minimal record
            state: TrustState.pairingPending,
            updatedAt: DateTime.now().toUtc(),
            trustedEndpoints: [
              TrustedPeerEndpoint(
                address: '127.0.0.1',
                port: 23456, // Dummy port
                source: 'manual',
                addressFamily: 'IPv4',
                lastSuccessAt: DateTime.now().toUtc(),
              ),
            ],
          ),
        );
        trustStore.dispose();

        // 2. Start RiftDaemon using the same storage path, discovery disabled
        final daemon = RiftDaemon(
          storagePath: tempDir.path,
          port: 0,
          enableDiscovery: false,
        );
        await daemon.start();

        // 3. Attempt to pair with the peer
        try {
          await daemon.handleJsonRpcRequest({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'rift.startPairing',
            'params': {'deviceId': 'rift-test-peer'},
          });
          fail('Should have thrown due to dummy server');
        } catch (e) {
          // We expect it to fail after attempting the trusted endpoint,
          // which means it throws RiftException rather than RiftNotFoundException.
          final errorStr = e.toString();
          expect(errorStr, contains('across all endpoints'));
          expect(errorStr, isNot(contains('Peer not found')));
        }

        await daemon.stop();
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );
}
