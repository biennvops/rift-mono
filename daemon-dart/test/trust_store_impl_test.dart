import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'package:daemon_dart/src/crypto/trust_store_impl.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';

void main() {
  group('TrustStoreImpl Tests', () {
    late Directory tempDir;

    setUp(() async {
      sqfliteFfiInit();
      tempDir = await Directory.systemTemp.createTemp('rift_trust_store_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Should persist and reload lastSeenAt for trust records', () async {
      final store = TrustStoreImpl(tempDir.path);
      await store.initialize();

      final now = DateTime.utc(2026, 6, 17, 10, 30, 45);
      await store.saveTrustRecord(
        TrustRecord(
          deviceId: 'rift-peer-a',
          ed25519PublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
          fingerprint: 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
          state: TrustState.trusted,
          lastSeenAt: now,
        ),
      );

      final reloaded = await store.getTrustRecord('rift-peer-a');
      expect(reloaded, isNotNull);
      expect(reloaded!.lastSeenAt?.toUtc().toIso8601String(), equals(now.toIso8601String()));
    });

    test('Should update lastSeenAt without changing trust state', () async {
      final store = TrustStoreImpl(tempDir.path);
      await store.initialize();

      await store.saveTrustRecord(
        TrustRecord(
          deviceId: 'rift-peer-b',
          ed25519PublicKey: Uint8List.fromList(List<int>.filled(32, 3)),
          fingerprint: 'WXYZ-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
          state: TrustState.trusted,
        ),
      );

      final seenAt = DateTime.utc(2026, 6, 17, 11, 0, 0);
      await store.updateLastSeen('rift-peer-b', seenAt);

      final updated = await store.getTrustRecord('rift-peer-b');
      expect(updated, isNotNull);
      expect(updated!.state, equals(TrustState.trusted));
      expect(updated.lastSeenAt?.toUtc().toIso8601String(), equals(seenAt.toIso8601String()));
    });

    test('Should migrate v1 databases to include lastSeenAt column', () async {
      final dbPath = p.join(tempDir.path, 'trust_store.db');
      final db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE trusted_peers (
                deviceId TEXT PRIMARY KEY,
                ed25519PublicKey BLOB NOT NULL,
                fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                updatedAt TEXT NOT NULL
              )
            ''');
          },
        ),
      );
      await db.insert('trusted_peers', {
        'deviceId': 'rift-peer-c',
        'ed25519PublicKey': Uint8List.fromList(List<int>.filled(32, 9)),
        'fingerprint': 'LMNO-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567',
        'state': 'trusted',
        'updatedAt': DateTime.utc(2026, 6, 17, 12, 0, 0).toIso8601String(),
      });
      await db.close();

      final migratedStore = TrustStoreImpl(tempDir.path);
      await migratedStore.initialize();
      await migratedStore.updateLastSeen(
        'rift-peer-c',
        DateTime.utc(2026, 6, 17, 12, 15, 0),
      );

      final migrated = await migratedStore.getTrustRecord('rift-peer-c');
      expect(migrated, isNotNull);
      expect(migrated!.state, equals(TrustState.trusted));
      expect(migrated.lastSeenAt, isNotNull);
    });
  });
}
