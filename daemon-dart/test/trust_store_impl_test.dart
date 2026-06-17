import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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
  });
}
