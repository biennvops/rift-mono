import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';

void main() {
  group('TrustStoreImpl Tests', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rift_trust_store_test');
      dbPath = p.join(tempDir.path, 'trust_store.db');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Should persist and reload lastSeenAt for trust records', () async {
      final store = TrustStoreImpl(dbPath);
      await store.initialize();

      final now = DateTime.utc(2026, 6, 17, 10, 30, 45);
      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-a',
          certDer: Uint8List.fromList(List<int>.filled(32, 7)),
          state: TrustState.trusted,
          updatedAt: now,
          lastSeenAt: now,
        ),
      );

      await store.updateLastSeen('rift-peer-a', now);
      final reloaded = await store.getPeer('rift-peer-a');
      expect(reloaded, isNotNull);
      expect(reloaded!.lastSeenAt?.toUtc().toIso8601String(), now.toIso8601String());
      store.dispose();
    });

    test('Should update lastSeenAt without changing trust state', () async {
      final store = TrustStoreImpl(dbPath);
      await store.initialize();

      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-b',
          certDer: Uint8List.fromList(List<int>.filled(32, 3)),
          state: TrustState.trusted,
          updatedAt: DateTime.utc(2026, 6, 17, 11, 0, 0),
        ),
      );

      final seenAt = DateTime.utc(2026, 6, 17, 11, 15, 0);
      await store.updateLastSeen('rift-peer-b', seenAt);

      final updated = await store.getPeer('rift-peer-b');
      expect(updated, isNotNull);
      expect(updated!.state, TrustState.trusted);
      expect(updated.lastSeenAt?.toUtc().toIso8601String(), seenAt.toIso8601String());
      store.dispose();
    });

    test('Should migrate v1 databases to include lastSeenAt column', () async {
      final db = sqlite3.open(dbPath);
      db.execute('''
        CREATE TABLE config (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE TABLE peers (
          device_id    TEXT PRIMARY KEY,
          display_name TEXT,
          cert_der     BLOB NOT NULL,
          state        TEXT NOT NULL,
          paired_at    INTEGER,
          updated_at   INTEGER NOT NULL
        );
      ''');
      db.execute("INSERT INTO config (key, value) VALUES ('schema_version', '1')");
      db.execute(
        '''
        INSERT INTO peers (device_id, display_name, cert_der, state, paired_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [
          'rift-peer-c',
          'Peer C',
          Uint8List.fromList(List<int>.filled(32, 9)),
          'trusted',
          null,
          DateTime.utc(2026, 6, 17, 12, 0, 0).millisecondsSinceEpoch,
        ],
      );
      db.dispose();

      final migratedStore = TrustStoreImpl(dbPath);
      await migratedStore.initialize();
      await migratedStore.updateLastSeen(
        'rift-peer-c',
        DateTime.utc(2026, 6, 17, 12, 15, 0),
      );

      final migrated = await migratedStore.getPeer('rift-peer-c');
      expect(migrated, isNotNull);
      expect(migrated!.state, TrustState.trusted);
      expect(migrated.lastSeenAt, isNotNull);
      migratedStore.dispose();
    });

    test('Should persist and query security events from SQLite', () async {
      final store = TrustStoreImpl(dbPath);
      await store.initialize();

      await store.appendSecurityEvent(
        SecurityEventRecord(
          eventId: 'evt-1',
          eventType: 'pairing.completed',
          severity: 'info',
          localDeviceId: 'rift-local',
          peerDeviceId: 'rift-peer-a',
          timestamp: DateTime.utc(2026, 6, 24, 1, 2, 3),
          outcome: 'success',
          details: {'source': 'test'},
        ),
      );
      await store.appendSecurityEvent(
        SecurityEventRecord(
          eventId: 'evt-2',
          eventType: 'trust.revoked',
          severity: 'warning',
          localDeviceId: 'rift-local',
          peerDeviceId: 'rift-peer-b',
          timestamp: DateTime.utc(2026, 6, 24, 1, 3, 4),
          outcome: 'success',
          failureReason: 'manual',
        ),
      );

      final warningOnly = await store.querySecurityEvents(
        const SecurityEventQuery(severities: ['warning']),
      );
      expect(warningOnly, hasLength(1));
      expect(warningOnly.single.eventId, 'evt-2');
      expect(warningOnly.single.failureReason, 'manual');

      final totalWarnings = await store.countSecurityEvents(
        const SecurityEventQuery(severities: ['warning']),
      );
      expect(totalWarnings, 1);

      final reloaded = TrustStoreImpl(dbPath);
      await reloaded.initialize();
      final allEvents = await reloaded.querySecurityEvents(
        const SecurityEventQuery(limit: 10),
      );
      expect(allEvents, hasLength(2));
      expect(allEvents.first.eventId, 'evt-2');
      expect(allEvents.last.eventId, 'evt-1');
      expect(allEvents.last.details?['source'], 'test');

      store.dispose();
      reloaded.dispose();
    });

    test('Should migrate v2 databases to include security_events table', () async {
      final db = sqlite3.open(dbPath);
      db.execute('''
        CREATE TABLE config (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE TABLE peers (
          device_id    TEXT PRIMARY KEY,
          display_name TEXT,
          cert_der     BLOB NOT NULL,
          state        TEXT NOT NULL,
          paired_at    INTEGER,
          updated_at   INTEGER NOT NULL,
          last_seen_at INTEGER
        );
      ''');
      db.execute("INSERT INTO config (key, value) VALUES ('schema_version', '2')");
      db.dispose();

      final migratedStore = TrustStoreImpl(dbPath);
      await migratedStore.initialize();
      await migratedStore.appendSecurityEvent(
        SecurityEventRecord(
          eventId: 'evt-migrate',
          eventType: 'connection.established',
          severity: 'info',
          localDeviceId: 'rift-local',
          timestamp: DateTime.utc(2026, 6, 24, 2, 0, 0),
          outcome: 'success',
        ),
      );

      final events = await migratedStore.querySecurityEvents(
        const SecurityEventQuery(limit: 10),
      );
      expect(events, hasLength(1));
      expect(events.single.eventId, 'evt-migrate');
      migratedStore.dispose();
    });

    test('Should enforce valid trust state transitions (fail closed)', () async {
      final store = TrustStoreImpl(':memory:');
      await store.initialize();

      final now = DateTime.utc(2026, 6, 19, 0, 0, 0);
      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-transition',
          certDer: Uint8List.fromList(List<int>.filled(32, 1)),
          state: TrustState.discovered,
          updatedAt: now,
        ),
      );

      // Valid: discovered -> pairingPending
      final ok1 = await store.transitionState('rift-peer-transition', TrustState.discovered, TrustState.pairingPending);
      expect(ok1, isTrue);

      // Invalid: pairingPending -> revoked is allowed, but revoked -> trusted is not.
      final ok2 = await store.transitionState('rift-peer-transition', TrustState.pairingPending, TrustState.revoked);
      expect(ok2, isTrue);

      expect(
        () => store.transitionState('rift-peer-transition', TrustState.revoked, TrustState.trusted),
        throwsA(isA<Exception>()),
      );

      store.dispose();
    });

    test('Should prevent mDNS downgrade from overwriting pinned cert_der for trusted peers', () async {
      final store = TrustStoreImpl(':memory:');
      await store.initialize();

      final certA = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final certB = Uint8List.fromList(List<int>.filled(32, 9));

      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-pinned-cert',
          certDer: certA,
          state: TrustState.trusted,
          updatedAt: DateTime.utc(2026, 6, 19, 0, 0, 0),
        ),
      );

      // Simulate discovery re-seeing the peer with a different cert.
      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-pinned-cert',
          certDer: certB,
          state: TrustState.discovered,
          updatedAt: DateTime.utc(2026, 6, 19, 0, 1, 0),
        ),
      );

      final reloaded = await store.getPeer('rift-peer-pinned-cert');
      expect(reloaded, isNotNull);
      expect(reloaded!.state, TrustState.trusted);
      expect(reloaded.certDer, certA);

      store.dispose();
    });

    test('Should round-trip cert_der BLOB and list peers by state', () async {
      final store = TrustStoreImpl(':memory:');
      await store.initialize();

      final cert = Uint8List.fromList(List<int>.generate(256, (i) => i % 256));
      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-blob',
          certDer: cert,
          state: TrustState.blocked,
          updatedAt: DateTime.utc(2026, 6, 19, 0, 0, 0),
        ),
      );

      final loaded = await store.getPeer('rift-peer-blob');
      expect(loaded, isNotNull);
      expect(loaded!.certDer, cert);

      final blocked = await store.getPeersByState(TrustState.blocked);
      expect(blocked.map((p) => p.deviceId).toList(), contains('rift-peer-blob'));

      store.dispose();
    });

    test('Should forbid hard-delete for non-discovered peers (preserve negative-trust evidence)', () async {
      final store = TrustStoreImpl(':memory:');
      await store.initialize();

      await store.upsertPeer(
        PeerRecord(
          deviceId: 'rift-peer-no-delete',
          certDer: Uint8List.fromList(List<int>.filled(32, 2)),
          state: TrustState.revoked,
          updatedAt: DateTime.utc(2026, 6, 19, 0, 0, 0),
        ),
      );

      expect(
        () => store.deletePeer('rift-peer-no-delete'),
        throwsA(isA<RiftAuthenticationFailedException>()),
      );

      store.dispose();
    });
  });
}
