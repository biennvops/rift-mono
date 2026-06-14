import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import '../interfaces/trust_store.dart';

class TrustStoreImpl implements TrustStore {
  final String dbPath;
  Database? _db;

  TrustStoreImpl(this.dbPath);

  @override
  Future<void> initialize() async {
    if (dbPath != ':memory:') {
      final file = File(dbPath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
    }
    
    _db = sqlite3.open(dbPath);
    
    // Use WAL mode to avoid lock contention
    _db!.execute('PRAGMA journal_mode=WAL;');
    
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS peers (
        device_id    TEXT PRIMARY KEY,
        display_name TEXT,
        cert_der     BLOB NOT NULL,
        state        TEXT NOT NULL,
        paired_at    INTEGER,
        updated_at   INTEGER NOT NULL
      );
    ''');
  }

  @override
  Future<void> upsertPeer(PeerRecord record) async {
    _ensureInitialized();
    final stmt = _db!.prepare('''
      INSERT INTO peers (device_id, display_name, cert_der, state, paired_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        display_name = excluded.display_name,
        cert_der = excluded.cert_der,
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
      throw StateError('Invalid state transition from ${from.name} to ${to.name}.');
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
  Future<void> deletePeer(String deviceId) async {
    _ensureInitialized();
    // SECURITY HARDENING: AGENTS.md dictates "Revocation keeps negative-trust evidence".
    // We only allow Hard Deletion for transient mDNS garbage collection.
    // Trusted, Blocked, or Revoked peers MUST NOT be deleted.
    final record = await getPeer(deviceId);
    if (record != null && record.state != TrustState.discovered) {
      throw StateError('SecurityError: Cannot hard-delete peer in state ${record.state.name}. Must preserve trust evidence.');
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
    );
  }
  
  void _ensureInitialized() {
    if (_db == null) {
      throw StateError('TrustStore has not been initialized. Call initialize() first.');
    }
  }
  
  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
