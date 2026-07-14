import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
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
        last_seen_at INTEGER,
        trusted_endpoints_json TEXT
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
      currentVersion = 2;
    }

    if (currentVersion < 3) {
      _db!.execute('''
        CREATE TABLE IF NOT EXISTS security_events (
          event_id       TEXT PRIMARY KEY,
          event_type     TEXT NOT NULL,
          severity       TEXT NOT NULL,
          local_device_id TEXT NOT NULL,
          peer_device_id TEXT,
          timestamp      TEXT NOT NULL,
          outcome        TEXT NOT NULL,
          failure_reason TEXT,
          details_json   TEXT
        );
      ''');
      _db!.execute('''
        CREATE INDEX IF NOT EXISTS idx_security_events_timestamp
        ON security_events (timestamp DESC);
      ''');
      _db!.execute('''
        CREATE INDEX IF NOT EXISTS idx_security_events_event_type
        ON security_events (event_type, timestamp DESC);
      ''');
      _db!.execute('''
        CREATE INDEX IF NOT EXISTS idx_security_events_severity
        ON security_events (severity, timestamp DESC);
      ''');
      _db!.execute('''
        CREATE INDEX IF NOT EXISTS idx_security_events_peer
        ON security_events (peer_device_id, timestamp DESC);
      ''');
      _db!.execute("UPDATE config SET value = '3' WHERE key = 'schema_version'");
      currentVersion = 3;
    }

    if (currentVersion < 4) {
      try {
        _db!.execute(
          "ALTER TABLE peers ADD COLUMN trusted_endpoints_json TEXT;",
        );
      } on SqliteException catch (e) {
        final msg = e.message.toLowerCase();
        if (!msg.contains('duplicate column') && !msg.contains('already exists')) {
          rethrow;
        }
      }
      _db!.execute("UPDATE config SET value = '4' WHERE key = 'schema_version'");
    }
  }

  @override
  Future<void> upsertPeer(PeerRecord record) async {
    _ensureInitialized();
    final stmt = _db!.prepare('''
      INSERT INTO peers (
        device_id,
        display_name,
        cert_der,
        state,
        paired_at,
        updated_at,
        last_seen_at,
        trusted_endpoints_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        display_name = excluded.display_name,
        cert_der = CASE
          WHEN peers.state IN ('trusted', 'blocked', 'revoked') THEN peers.cert_der
          ELSE excluded.cert_der
        END,
        last_seen_at = COALESCE(excluded.last_seen_at, peers.last_seen_at),
        trusted_endpoints_json = COALESCE(
          excluded.trusted_endpoints_json,
          peers.trusted_endpoints_json
        ),
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
        record.trustedEndpoints.isEmpty
            ? null
            : jsonEncode(
                record.trustedEndpoints
                    .map((endpoint) => endpoint.toJson())
                    .toList(growable: false),
              ),
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
  Future<List<PeerRecord>> getAllPeers() async {
    _ensureInitialized();
    final stmt = _db!.prepare('SELECT * FROM peers');
    try {
      final ResultSet results = stmt.select();
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
    final stmt = _db!.prepare('DELETE FROM peers WHERE device_id = ?');
    try {
      stmt.execute([deviceId]);
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<void> appendSecurityEvent(SecurityEventRecord record) async {
    _ensureInitialized();
    final stmt = _db!.prepare('''
      INSERT INTO security_events (
        event_id,
        event_type,
        severity,
        local_device_id,
        peer_device_id,
        timestamp,
        outcome,
        failure_reason,
        details_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''');
    try {
      stmt.execute([
        record.eventId,
        record.eventType,
        record.severity,
        record.localDeviceId,
        record.peerDeviceId,
        record.timestamp.toUtc().toIso8601String(),
        record.outcome,
        record.failureReason,
        record.details == null ? null : jsonEncode(record.details),
      ]);
      _db!.execute('''
        DELETE FROM security_events
        WHERE event_id NOT IN (
          SELECT event_id
          FROM security_events
          ORDER BY timestamp DESC
          LIMIT 10000
        );
      ''');
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<List<SecurityEventRecord>> querySecurityEvents(
    SecurityEventQuery query,
  ) async {
    _ensureInitialized();

    final (whereSql, bindings) = _buildSecurityEventWhereClause(query);
    final stmt = _db!.prepare('''
      SELECT *
      FROM security_events
      $whereSql
      ORDER BY timestamp DESC
      LIMIT ? OFFSET ?;
    ''');

    try {
      final results = stmt.select([...bindings, query.limit, query.offset]);
      return results.map(_rowToSecurityEventRecord).toList();
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<int> countSecurityEvents(SecurityEventQuery query) async {
    _ensureInitialized();
    final (whereSql, bindings) = _buildSecurityEventWhereClause(query);
    final stmt = _db!.prepare('''
      SELECT COUNT(*) AS count
      FROM security_events
      $whereSql;
    ''');
    try {
      final results = stmt.select(bindings);
      if (results.isEmpty) {
        return 0;
      }
      return results.first['count'] as int? ?? 0;
    } finally {
      stmt.dispose();
    }
  }
  
  PeerRecord _rowToPeerRecord(Row row) {
    final pairedAtMs = row['paired_at'] as int?;
    final lastSeenAtMs = row['last_seen_at'] as int?;
    final trustedEndpointsJson = row['trusted_endpoints_json'] as String?;
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
      trustedEndpoints: _decodeTrustedEndpoints(trustedEndpointsJson),
    );
  }

  List<TrustedPeerEndpoint> _decodeTrustedEndpoints(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException(
        'trusted_endpoints_json must decode to a JSON array',
      );
    }

    return decoded
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException(
              'trusted_endpoints_json entries must be JSON objects',
            );
          }
          return TrustedPeerEndpoint.fromJson(
            Map<String, dynamic>.from(entry),
          );
        })
        .toList(growable: false);
  }

  SecurityEventRecord _rowToSecurityEventRecord(Row row) {
    final detailsJson = row['details_json'] as String?;
    return SecurityEventRecord(
      eventId: row['event_id'] as String,
      eventType: row['event_type'] as String,
      severity: row['severity'] as String,
      localDeviceId: row['local_device_id'] as String,
      peerDeviceId: row['peer_device_id'] as String?,
      timestamp: DateTime.parse(row['timestamp'] as String).toUtc(),
      outcome: row['outcome'] as String,
      failureReason: row['failure_reason'] as String?,
      details: detailsJson == null || detailsJson.isEmpty
          ? null
          : Map<String, dynamic>.from(jsonDecode(detailsJson) as Map),
    );
  }

  (String, List<Object?>) _buildSecurityEventWhereClause(
    SecurityEventQuery query,
  ) {
    final whereClauses = <String>[];
    final bindings = <Object?>[];

    if (query.eventTypes != null && query.eventTypes!.isNotEmpty) {
      whereClauses.add(
        'event_type IN (${List.filled(query.eventTypes!.length, '?').join(', ')})',
      );
      bindings.addAll(query.eventTypes!);
    }

    if (query.severities != null && query.severities!.isNotEmpty) {
      whereClauses.add(
        'severity IN (${List.filled(query.severities!.length, '?').join(', ')})',
      );
      bindings.addAll(query.severities!);
    }

    if (query.peerDeviceId != null && query.peerDeviceId!.isNotEmpty) {
      whereClauses.add('peer_device_id = ?');
      bindings.add(query.peerDeviceId);
    }

    if (query.since != null) {
      whereClauses.add('timestamp >= ?');
      bindings.add(query.since!.toUtc().toIso8601String());
    }

    final whereSql = whereClauses.isEmpty
        ? ''
        : 'WHERE ${whereClauses.join(' AND ')}';
    return (whereSql, bindings);
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
