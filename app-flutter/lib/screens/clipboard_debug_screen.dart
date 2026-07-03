import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';

class ClipboardDebugScreen extends StatefulWidget {
  const ClipboardDebugScreen({super.key});

  @override
  State<ClipboardDebugScreen> createState() => _ClipboardDebugScreenState();
}

class _ClipboardDebugScreenState extends State<ClipboardDebugScreen> {
  final TextEditingController _offerIdController = TextEditingController();
  final List<Map<String, dynamic>> _offers = [];

  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _expiredSub;

  String _eventLog = 'No clipboard events yet.';
  String? _fetchedText;
  String? _fetchError;
  bool _isRefreshing = false;
  bool _isFetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClipboardEvents();
      _refreshOffers();
    });
  }

  @override
  void dispose() {
    _offerSub?.cancel();
    _expiredSub?.cancel();
    _offerIdController.dispose();
    super.dispose();
  }

  void _bindClipboardEvents() {
    final client = context.read<JsonRpcRiftClient>();
    _offerSub = client.onClipboardOffer.listen((event) {
      if (!mounted) return;
      setState(() {
        _eventLog =
            'onClipboardOffer: ${event['offerId']} from ${event['sourceDeviceId']} (${event['byteSize']} bytes)';
      });
      unawaited(_refreshOffers());
    });

    _expiredSub = client.onClipboardExpired.listen((event) {
      if (!mounted) return;
      setState(() {
        _eventLog = 'onClipboardExpired: ${event['offerId']}';
      });
      unawaited(_refreshOffers());
    });
  }

  Future<void> _refreshOffers() async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _isRefreshing = true;
      _fetchError = null;
    });

    try {
      final result = await client.listClipboardOffers();
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (!mounted) return;
      setState(() {
        _offers
          ..clear()
          ..addAll(offers);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchError = 'List offers failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _fetchOffer(String offerId) async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _isFetching = true;
      _fetchError = null;
      _fetchedText = null;
      _offerIdController.text = offerId;
    });

    try {
      final result = Map<String, dynamic>.from(
        await client.fetchClipboardContent(offerId) as Map,
      );
      final contentBase64 = result['contentBase64'] as String;
      final decodedBytes = base64.decode(contentBase64);
      String decodedText;
      try {
        decodedText = utf8.decode(decodedBytes);
      } on FormatException {
        decodedText =
            'Non-text clipboard payload (${decodedBytes.length} bytes, valid base64 but not UTF-8 text)';
      }
      if (!mounted) return;
      setState(() {
        _fetchedText = decodedText;
        _eventLog =
            'fetchClipboardContent: ${result['offerId']} verified=${result['verified']}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchError = 'Fetch failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFetching = false;
        });
      }
    }
  }

  Widget _buildOfferCard(Map<String, dynamic> offer) {
    final offerId = offer['offerId']?.toString() ?? '';
    final sourceDeviceId = offer['sourceDeviceId']?.toString() ?? 'unknown';
    final byteSize = offer['byteSize']?.toString() ?? '?';
    final expiresAt = offer['expiresAt']?.toString() ?? '-';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              offerId,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Text('Source: $sourceDeviceId'),
            Text('Size: $byteSize bytes'),
            Text('Expires: $expiresAt'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _isFetching ? null : () => _fetchOffer(offerId),
                child: const Text('Fetch'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard Debug'),
        actions: [
          IconButton(
            onPressed: _isRefreshing ? null : _refreshOffers,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last Event',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_eventLog),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _offerIdController,
            decoration: InputDecoration(
              labelText: 'Offer ID',
              suffixIcon: IconButton(
                onPressed: _isFetching
                    ? null
                    : () {
                        final offerId = _offerIdController.text.trim();
                        if (offerId.isEmpty) return;
                        _fetchOffer(offerId);
                      },
                icon: const Icon(Icons.download),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_fetchError != null)
            Text(
              _fetchError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_fetchedText != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Fetched Text',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(_fetchedText!),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Peer Offers',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (_isRefreshing)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_offers.isEmpty)
            const Text('No active peer offers.')
          else
            ..._offers.map(_buildOfferCard),
        ],
      ),
    );
  }
}
