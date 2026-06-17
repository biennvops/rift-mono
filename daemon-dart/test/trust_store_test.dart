import 'dart:ffi';
import 'dart:typed_data';
import 'package:sqlite3/open.dart';
import 'package:test/test.dart';
import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';

DynamicLibrary _openOnLinux() {
  return DynamicLibrary.open('libsqlite3.so.0');
}

void main() {
  open.overrideFor(OperatingSystem.linux, _openOnLinux);

  group('TrustStoreImpl Tests', () {
    late TrustStoreImpl trustStore;

    setUp(() async {
      // Use :memory: to create in-memory database, auto-destroys when closed
      trustStore = TrustStoreImpl(':memory:');
      await trustStore.initialize();
    });

    tearDown(() async {
      trustStore.dispose();
    });

    test('Insert new peer -> state discovered and save Cert DER byte-perfect', () async {
      final certDer = Uint8List.fromList([1, 2, 3, 255, 0, 128]);
      final now = DateTime.now().toUtc();
      
      final record = PeerRecord(
        deviceId: 'rift-test1',
        displayName: 'Test Device',
        certDer: certDer,
        state: TrustState.discovered,
        updatedAt: now,
      );

      await trustStore.upsertPeer(record);

      final fetched = await trustStore.getPeer('rift-test1');
      expect(fetched, isNotNull);
      expect(fetched!.deviceId, 'rift-test1');
      expect(fetched.displayName, 'Test Device');
      expect(fetched.state, TrustState.discovered);
      
      // Test 6: Cert DER saved and read back byte-perfect (BLOB round-trip)
      expect(fetched.certDer, equals(certDer));
      
      // Ensure datetime has standard UTC timezone
      expect(fetched.updatedAt.isUtc, isTrue);
      expect(fetched.updatedAt.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    });

    test('Valid transition: discovered -> pairing_pending', () async {
      final record = PeerRecord(
        deviceId: 'rift-test2',
        certDer: Uint8List.fromList([1, 2, 3]),
        state: TrustState.discovered,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      
      final success = await trustStore.transitionState('rift-test2', TrustState.discovered, TrustState.pairingPending);
      expect(success, isTrue);
      
      final fetched = await trustStore.getPeer('rift-test2');
      expect(fetched!.state, TrustState.pairingPending);
    });

    test('Valid transition: pairing_pending -> trusted and update pairedAt', () async {
      final record = PeerRecord(
        deviceId: 'rift-test3',
        certDer: Uint8List.fromList([1, 2, 3]),
        state: TrustState.pairingPending,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      
      final pairedTime = DateTime.now().toUtc();
      final success = await trustStore.transitionState(
        'rift-test3', 
        TrustState.pairingPending, 
        TrustState.trusted,
        pairedAt: pairedTime,
      );
      expect(success, isTrue);
      
      final fetched = await trustStore.getPeer('rift-test3');
      expect(fetched!.state, TrustState.trusted);
      expect(fetched.pairedAt, isNotNull);
      expect(fetched.pairedAt!.millisecondsSinceEpoch, pairedTime.millisecondsSinceEpoch);
    });

    test('upsertPeer does NOT overwrite state (prevents mDNS downgrade)', () async {
      final record = PeerRecord(
        deviceId: 'rift-test-downgrade',
        certDer: Uint8List.fromList([1, 2, 3]),
        state: TrustState.trusted,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      
      // mDNS finds peer again, sends discovered packet
      final discoveryRecord = PeerRecord(
        deviceId: 'rift-test-downgrade',
        certDer: Uint8List.fromList([4, 5, 6]),
        state: TrustState.discovered, // Intentional downgrade
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(discoveryRecord);
      
      final fetched = await trustStore.getPeer('rift-test-downgrade');
      expect(fetched!.state, TrustState.trusted, reason: 'State MUST NOT be overwritten');
      expect(fetched.certDer, Uint8List.fromList([1, 2, 3]), reason: 'Pinned certDer MUST NOT be overwritten');
    });

    test('Invalid transition is rejected (revoked -> trusted)', () async {
      final record = PeerRecord(
        deviceId: 'rift-test4',
        certDer: Uint8List.fromList([1, 2, 3]),
        state: TrustState.revoked,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      
      // Direct transition from revoked to trusted must throw InvalidTransition
      expect(
        () => trustStore.transitionState('rift-test4', TrustState.revoked, TrustState.trusted),
        throwsA(isA<RiftInvalidTransitionException>()),
      );
      
      // State must remain revoked
      final fetched = await trustStore.getPeer('rift-test4');
      expect(fetched!.state, TrustState.revoked);
    });

    test('getPeersByState returns correct list', () async {
      final now = DateTime.now().toUtc();
      
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-p1', certDer: Uint8List(0), state: TrustState.trusted, updatedAt: now
      ));
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-p2', certDer: Uint8List(0), state: TrustState.trusted, updatedAt: now
      ));
      await trustStore.upsertPeer(PeerRecord(
        deviceId: 'rift-p3', certDer: Uint8List(0), state: TrustState.discovered, updatedAt: now
      ));

      final trustedPeers = await trustStore.getPeersByState(TrustState.trusted);
      expect(trustedPeers.length, 2);
      expect(trustedPeers.map((e) => e.deviceId).toSet(), {'rift-p1', 'rift-p2'});

      final discoveredPeers = await trustStore.getPeersByState(TrustState.discovered);
      expect(discoveredPeers.length, 1);
      expect(discoveredPeers.first.deviceId, 'rift-p3');
      
      final blockedPeers = await trustStore.getPeersByState(TrustState.blocked);
      expect(blockedPeers, isEmpty);
    });
    
    test('Successfully deleted peer', () async {
      final record = PeerRecord(
        deviceId: 'rift-del',
        certDer: Uint8List.fromList([1]),
        state: TrustState.discovered,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      expect(await trustStore.getPeer('rift-del'), isNotNull);
      
      await trustStore.deletePeer('rift-del');
      expect(await trustStore.getPeer('rift-del'), isNull);
    });
    test('Cannot delete non-discovered peer (preserves negative trust evidence)', () async {
      final record = PeerRecord(
        deviceId: 'rift-del-fail',
        certDer: Uint8List.fromList([1]),
        state: TrustState.trusted,
        updatedAt: DateTime.now().toUtc(),
      );
      
      await trustStore.upsertPeer(record);
      
      expect(
        () => trustStore.deletePeer('rift-del-fail'),
        throwsA(isA<RiftAuthenticationFailedException>()),
      );
      
      // Must still exist
      final fetched = await trustStore.getPeer('rift-del-fail');
      expect(fetched, isNotNull);
      expect(fetched!.state, TrustState.trusted);
    });
  });
}
