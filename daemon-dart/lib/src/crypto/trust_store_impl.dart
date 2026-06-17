import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../interfaces/trust_store.dart';

class TrustStoreImpl implements TrustStore {
  final String dbPath;
  late final Database _db;

  TrustStoreImpl(this.dbPath);

  @override
  Future<void> initialize() async {
    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;
    
    final path = join(dbPath, 'trust_store.db');
    // Ensure directory exists
    final dir = Directory(dbPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE trusted_peers (
              deviceId TEXT PRIMARY KEY,
              ed25519PublicKey BLOB NOT NULL,
              fingerprint TEXT NOT NULL,
              state TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              lastSeenAt TEXT
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('ALTER TABLE trusted_peers ADD COLUMN lastSeenAt TEXT');
          }
        },
      ),
    );
  }

  @override
  Future<void> saveTrustRecord(TrustRecord record) async {
    await _db.insert(
      'trusted_peers',
      {
        'deviceId': record.deviceId,
        'ed25519PublicKey': record.ed25519PublicKey,
        'fingerprint': record.fingerprint,
        'state': record.state.toJson(),
        'updatedAt': DateTime.now().toIso8601String(),
        'lastSeenAt': record.lastSeenAt?.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<TrustRecord?> getTrustRecord(String deviceId) async {
    final maps = await _db.query(
      'trusted_peers',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );

    if (maps.isEmpty) return null;

    final row = maps.first;
    return TrustRecord(
      deviceId: row['deviceId'] as String,
      ed25519PublicKey: row['ed25519PublicKey'] as Uint8List,
      fingerprint: row['fingerprint'] as String,
      state: TrustState.fromJson(row['state'] as String),
      lastSeenAt: row['lastSeenAt'] != null ? DateTime.tryParse(row['lastSeenAt'] as String) : null,
    );
  }

  @override
  Future<List<TrustRecord>> getAllTrustRecords() async {
    final maps = await _db.query('trusted_peers');
    return maps.map((row) => TrustRecord(
      deviceId: row['deviceId'] as String,
      ed25519PublicKey: row['ed25519PublicKey'] as Uint8List,
      fingerprint: row['fingerprint'] as String,
      state: TrustState.fromJson(row['state'] as String),
      lastSeenAt: row['lastSeenAt'] != null ? DateTime.tryParse(row['lastSeenAt'] as String) : null,
    )).toList();
  }

  @override
  Future<TrustState> getTrustState(String deviceId) async {
    final record = await getTrustRecord(deviceId);
    return record?.state ?? TrustState.discovered;
  }

  @override
  Future<void> blockDevice(String deviceId) async {
    final record = await getTrustRecord(deviceId);
    if (record != null) {
      final updated = TrustRecord(
        deviceId: record.deviceId,
        ed25519PublicKey: record.ed25519PublicKey,
        fingerprint: record.fingerprint,
        state: TrustState.blocked,
      );
      await saveTrustRecord(updated);
    }
  }

  @override
  Future<void> revokeDevice(String deviceId, {required String reason}) async {
    final record = await getTrustRecord(deviceId);
    if (record != null) {
      final updated = TrustRecord(
        deviceId: record.deviceId,
        ed25519PublicKey: record.ed25519PublicKey,
        fingerprint: record.fingerprint,
        state: TrustState.revoked,
      );
      await saveTrustRecord(updated);
    }
  }

  @override
  Future<void> unblockDevice(String deviceId) async {
    final record = await getTrustRecord(deviceId);
    if (record != null && record.state == TrustState.blocked) {
      final updated = TrustRecord(
        deviceId: record.deviceId,
        ed25519PublicKey: record.ed25519PublicKey,
        fingerprint: record.fingerprint,
        state: TrustState.discovered,
      );
      await saveTrustRecord(updated);
    }
  }

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {
    await _db.update(
      'trusted_peers',
      {'lastSeenAt': lastSeenAt.toIso8601String()},
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }
}
