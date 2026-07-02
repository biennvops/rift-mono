import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'ipc/json_rpc_client.dart';

class ClipboardManager {
  final JsonRpcRiftClient _client;
  final _log = Logger('ClipboardManager');
  Timer? _pollTimer;
  String? _lastKnownClipboardText;
  StreamSubscription? _securityEventSub;

  final StreamController<String> _statusController = StreamController<String>.broadcast();
  Stream<String> get onStatusUpdate => _statusController.stream;

  ClipboardManager(this._client) {
    _startPolling();
    _listenToSecurityEvents();
  }

  void _startPolling() {
    // Poll the clipboard every 2 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_client.isConnected) return;
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        
        if (text != null && text.isNotEmpty && text != _lastKnownClipboardText) {
          _lastKnownClipboardText = text;
          await _sendClipboardToDaemon(text);
        }
      } catch (e) {
        _log.warning('Failed to read clipboard: $e');
      }
    });
  }

  void _listenToSecurityEvents() {
    _securityEventSub = _client.onSecurityEvent.listen((event) async {
      if (event['eventType'] == 'clipboard.offered') {
        _log.info('Received clipboard offer');
        final details = event['details'];
        if (details is Map && details['offerId'] != null) {
          final offerId = details['offerId'].toString();
          await _fetchClipboardFromDaemon(offerId);
        } else {
          // If offerId is not in details, we might need to fetch the list of offers
          final result = await _client.listClipboardOffers();
          if (result is Map && result['offers'] is List) {
            final offers = result['offers'] as List;
            if (offers.isNotEmpty) {
              final lastOffer = offers.last;
              final offerId = lastOffer['offerId']?.toString();
              if (offerId != null) {
                await _fetchClipboardFromDaemon(offerId);
              }
            }
          }
        }
      }
    });
  }

  Future<void> _sendClipboardToDaemon(String text) async {
    try {
      _statusController.add('Syncing clipboard to peers...');
      final bytes = utf8.encode(text);
      final byteSize = bytes.length;
      final hash = sha256.convert(bytes).toString().toLowerCase();
      final contentBase64 = base64Encode(bytes);

      await _client.notifyClipboardChange(
        'text/plain',
        byteSize,
        hash,
        contentBase64,
      );
      _statusController.add('Clipboard synced');
    } catch (e) {
      _log.severe('Failed to send clipboard to daemon: $e');
      _statusController.add('Failed to sync clipboard');
    }
  }

  Future<void> _fetchClipboardFromDaemon(String offerId) async {
    try {
      _statusController.add('Fetching incoming clipboard...');
      final response = await _client.fetchClipboardContent(offerId);
      
      if (response is Map && response['contentBase64'] != null) {
        final contentBase64 = response['contentBase64'].toString();
        final bytes = base64Decode(contentBase64);
        final text = utf8.decode(bytes);
        
        _lastKnownClipboardText = text; // Update so we don't echo it back
        await Clipboard.setData(ClipboardData(text: text));
        _statusController.add('Clipboard received from peer');
        _log.info('Successfully fetched and applied clipboard offer $offerId');
      }
    } catch (e) {
      _log.severe('Failed to fetch clipboard offer $offerId: $e');
      _statusController.add('Failed to fetch clipboard');
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _securityEventSub?.cancel();
    _statusController.close();
  }
}
