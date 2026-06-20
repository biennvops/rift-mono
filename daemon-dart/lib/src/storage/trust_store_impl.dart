import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';
import '../core/rift_exceptions.dart';
import '../interfaces/trust_store.dart';

DynamicLibrary _openSqliteOnLinux() {
  const candidates = <String>[
    'libsqlite3.so',
    'libsqlite3.so.0',
    '/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/lib/aarch64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
  ];

  Object? lastError;
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (error) {
      lastError = error;
    }
  }

  throw ArgumentError(
    'Failed to load sqlite3 dynamic library on Linux. Tried: ${candidates.join(', ')}. Last error: $lastError',
  );
}

class TrustStoreImpl implements TrustStore {
  final String dbPath;
  Database? _db;
  static bool _sqliteOpenConfigured = false;

  TrustStoreImpl(this.dbPath);

  @override
  Future<void> initialize() async {
    if (!_sqliteOpenConfigured && Platform.isLinux) {
      sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, _openSqliteOnLinux);
      _sqliteOpenConfigured = true;
    }

    if (dbPath != ':memory:') {
      final file = File(dbPath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
    }
    
    _db = sqlite3.open(dbPath);
    
    // Use WAL mode to avoid lock contention
    _db!.execute('PRAGMA journal_mode=WAL;');
    
    // Create config table for schema version tracking
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS config (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS peers (
        device_id    TEXT PRIMARY KEY,
        display_name TEXT,
        cert_der     BLOB NOT NULL,
        state        TEXT NOT NULL,
        paired_at    INTEGER,
        updated_at   INTEGER NOT NULL,
        last_seen_at INTEGER
      );
    ''');
    
    // Migration v1 -> v2 (Add last_seen_at)
    final versionResult = _db!.select("SELECT value FROM config WHERE key = 'schema_version'");
    int currentVersion = 1;
    if (versionResult.isNotEmpty) {
      currentVersion = int.tryParse(versionResult.first['value'] as String) ?? 1;
    } else {
      _db!.execute("INSERT INTO config (key, value) VALUES ('schema_version', '1')");
    }

    if (currentVersion < 2) {
      try {
        _db!.execute("ALTER TABLE peers ADD COLUMN last_seen_at INTEGER;");
      } on SqliteException catch (e) {
        // Column might already exist if migration failed halfway previously.
        // Fail closed on other sqlite errors (corruption, disk full, etc.).
        final msg = e.message.toLowerCase();
        if (!msg.contains('duplicate column') && !msg.contains('already exists')) {
          rethrow;
        }
      }
      _db!.execute("UPDATE config SET value = '2' WHERE key = 'schema_version'");
    }
  }

  @override
  Future<void> upsertPeer(PeerRecord record) async {
    _ensureInitialized();
    final stmt = _db!.prepare('''
      INSERT INTO peers (device_id, display_name, cert_der, state, paired_at, updated_at, last_seen_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        display_name = excluded.display_name,
        cert_der = CASE
          WHEN peers.state IN ('trusted', 'blocked', 'revoked') THEN peers.cert_der
          ELSE excluded.cert_der
        END,
        last_seen_at = COALESCE(excluded.last_seen_at, peers.last_seen_at),
        updated_at = excluded.updated_at;
    ''');
    
    // Note: ON CONFLICT does not overwrite `state` and `paired_at`
    // to prevent Discovery Service from automatically downgrading peer when mDNS finds it again.
    
    try {
      stmt.execute([
        record.deviceId,
        record.displayName,
        record.certDer,
        record.state.toJson(),
        record.pairedAt?.millisecondsSinceEpoch,
        record.updatedAt.millisecondsSinceEpoch,
        record.lastSeenAt?.toUtc().millisecondsSinceEpoch,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<PeerRecord?> getPeer(String deviceId) async {
    _ensureInitialized();
    final stmt = _db!.prepare('SELECT * FROM peers WHERE device_id = ?');
    try {
      final ResultSet results = stmt.select([deviceId]);
      if (results.isEmpty) return null;
      return _rowToPeerRecord(results.first);
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<List<PeerRecord>> getPeersByState(TrustState state) async {
    _ensureInitialized();
    final stmt = _db!.prepare('SELECT * FROM peers WHERE state = ?');
    try {
      final ResultSet results = stmt.select([state.toJson()]);
      return results.map(_rowToPeerRecord).toList();
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<bool> transitionState(String deviceId, TrustState from, TrustState to, {DateTime? pairedAt}) async {
    _ensureInitialized();
    
    // Validate all valid edges (Exhaustive Edge Validation)
    final isValid = switch ((from, to)) {
      (TrustState.discovered, TrustState.pairingPending) => true,
      (TrustState.pairingPending, TrustState.trusted) => true,
      (TrustState.pairingPending, TrustState.discovered) => true,
      (TrustState.pairingPending, TrustState.blocked) => true,
      (TrustState.pairingPending, TrustState.revoked) => true,
      (TrustState.trusted, TrustState.blocked) => true,
      (TrustState.trusted, TrustState.revoked) => true,
      (TrustState.blocked, TrustState.discovered) => true,
      (TrustState.revoked, TrustState.discovered) => true,
      _ => false,
    };

    if (!isValid) {
      throw RiftInvalidTransitionException('Invalid state transition from ${from.name} to ${to.name}.');
    }
    
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    
    if (pairedAt != null) {
      final stmt = _db!.prepare('''
        UPDATE peers 
        SET state = ?, updated_at = ?, paired_at = ?
        WHERE device_id = ? AND state = ?
      ''');
      try {
        stmt.execute([to.toJson(), now, pairedAt.toUtc().millisecondsSinceEpoch, deviceId, from.toJson()]);
        return _db!.updatedRows > 0;
      } finally {
        stmt.dispose();
      }
    } else {
      final stmt = _db!.prepare('''
        UPDATE peers 
        SET state = ?, updated_at = ?
        WHERE device_id = ? AND state = ?
      ''');
      try {
        stmt.execute([to.toJson(), now, deviceId, from.toJson()]);
        return _db!.updatedRows > 0;
      } finally {
        stmt.dispose();
      }
    }
  }

  @override
  Future<void> updateLastSeen(String deviceId, DateTime lastSeenAt) async {
    _ensureInitialized();
    final stmt = _db!.prepare('''
      UPDATE peers 
      SET last_seen_at = ?
      WHERE device_id = ?
    ''');
    try {
      stmt.execute([lastSeenAt.toUtc().millisecondsSinceEpoch, deviceId]);
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<void> deletePeer(String deviceId) async {
    _ensureInitialized();
    // SECURITY HARDENING: AGENTS.md dictates "Revocation keeps negative-trust evidence".
    // We only allow Hard Deletion for transient mDNS garbage collection.
    // Trusted, Blocked, or Revoked peers MUST NOT be deleted.
    final record = await getPeer(deviceId);
    if (record != null && record.state != TrustState.discovered) {
      throw RiftAuthenticationFailedException(
        'SecurityError: Cannot hard-delete peer in state ${record.state.name}. Must preserve trust evidence.',
      );
    }

    final stmt = _db!.prepare('DELETE FROM peers WHERE device_id = ? AND state = ?');
    try {
      stmt.execute([deviceId, TrustState.discovered.toJson()]);
    } finally {
      stmt.dispose();
    }
  }
  
  PeerRecord _rowToPeerRecord(Row row) {
    final pairedAtMs = row['paired_at'] as int?;
    final lastSeenAtMs = row['last_seen_at'] as int?;
    return PeerRecord(
      deviceId: row['device_id'] as String,
      displayName: row['display_name'] as String?,
      // Defensive copy (Immutable State rule in noiquy.md)
      certDer: Uint8List.fromList(row['cert_der'] as List<int>),
      state: TrustState.fromJson(row['state'] as String),
      // Must parse timestamp with isUtc: true per RFC 3339
      pairedAt: pairedAtMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(pairedAtMs, isUtc: true)
          : null,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int, isUtc: true),
      lastSeenAt: lastSeenAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenAtMs, isUtc: true)
          : null,
    );
  }
  
  void _ensureInitialized() {
    if (_db == null) {
      throw const RiftIdentityNotInitializedException(
        'TrustStore has not been initialized. Call initialize() first.',
      );
    }
  }
  
  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
