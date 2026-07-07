import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'pairing_screen.dart';

class ClipboardTransferScreen extends StatefulWidget {
  final String? deviceId;
  final String? displayName;

  const ClipboardTransferScreen({super.key, this.deviceId, this.displayName});

  @override
  State<ClipboardTransferScreen> createState() =>
      _ClipboardTransferScreenState();
}

class _ClipboardTransferScreenState extends State<ClipboardTransferScreen> with WidgetsBindingObserver {
  final List<Map<String, dynamic>> _offers = [];
  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _expiredSub;
  bool _isRefreshing = false;
  bool _isSending = false;
  final Set<String> _hiddenOfferIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClipboardEvents();
      _refreshOffers();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offerSub?.cancel();
    _expiredSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // We no longer auto-send clipboard on resume to prevent spam.
    // The user must explicitly press the send button or copy while the app is open.
  }

  void _bindClipboardEvents() {
    final client = context.read<JsonRpcRiftClient>();
    _offerSub = client.onClipboardOffer.listen((event) {
      if (!mounted) return;
      unawaited(_refreshOffers());
    });
    _expiredSub = client.onClipboardExpired.listen((event) {
      if (!mounted) return;
      unawaited(_refreshOffers());
    });
  }

  Future<void> _refreshOffers() async {
    final client = context.read<JsonRpcRiftClient>();
    setState(() => _isRefreshing = true);
    try {
      final result = await client.listClipboardOffers();
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List? ?? const <dynamic>[]).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (!mounted) return;
      
      // Filter hidden offers
      var visibleOffers = offers.where(
        (offer) => !_hiddenOfferIds.contains(offer['offerId']?.toString()),
      ).toList();

      // Sort descending by expiresAt (newest first)
      visibleOffers.sort((a, b) {
        final aTime = DateTime.tryParse(a['expiresAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = DateTime.tryParse(b['expiresAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

      // Deduplicate consecutive identical hashes
      final List<Map<String, dynamic>> dedupedOffers = [];
      String? lastHash;
      for (final offer in visibleOffers) {
        final currentHash = offer['sha256']?.toString();
        if (currentHash != null && currentHash != lastHash) {
          dedupedOffers.add(offer);
          lastHash = currentHash;
        }
      }

      // Limit to max 4
      if (dedupedOffers.length > 4) {
        dedupedOffers.removeRange(4, dedupedOffers.length);
      }

      setState(() {
        _offers.clear();
        _offers.addAll(dedupedOffers);
      });
    } catch (e) {
      // Handle error gracefully
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _sendCurrentClipboard() async {
    if (_isSending) return;
    setState(() => _isSending = true);
    final messenger = ScaffoldMessenger.of(context);
    
    try {
      // Wait a tiny bit for the window to actually gain focus after resumed
      await Future.delayed(const Duration(milliseconds: 500));
      
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty) {
        if (mounted) {
          messenger.showSnackBar(const SnackBar(content: Text('Clipboard is empty or not text!')));
          setState(() => _isSending = false);
        }
        return; // Nothing to send
      }

      final bytes = utf8.encode(text);
      final sha256Hash = sha256.convert(bytes).toString();
      final contentBase64 = base64Encode(bytes);

      if (!mounted) return;
      final client = context.read<JsonRpcRiftClient>();
      await client.notifyClipboardChange(
        contentType: 'text/plain',
        byteSize: bytes.length,
        sha256: sha256Hash,
        contentBase64: contentBase64,
      );
      
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Clipboard sent to peers!')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Failed to send clipboard: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _fetchOffer(Map<String, dynamic> offer) async {
    final client = context.read<JsonRpcRiftClient>();
    final messenger = ScaffoldMessenger.of(context);
    final offerId = offer['offerId']?.toString();
    if (offerId == null) return;
    
    try {
      await client.fetchClipboardContent(offerId);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Clipboard received!')),
      );
      await _refreshOffers();
    } catch (e) {
      if (!mounted) return;
      
      final errorStr = e.toString();
      if (errorStr.contains('-32004') || errorStr.contains('not trusted for protected reconnect')) {
        final sourceDeviceId = offer['sourceDeviceId']?.toString() ?? 'unknown';
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PairingScreen(
              initialDeviceId: sourceDeviceId,
              initialDisplayName: 'Rift Device', // Fallback, full name is fetched inside
              autoStart: true,
            ),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.displayName != null
        ? 'Clipboard — ${widget.displayName}'
        : 'Clipboard';
    final waitingOffers = _offers;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.primary,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshOffers,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_isRefreshing)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),

            // Manual Send Clipboard Action
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sync Current Clipboard',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Android restricts background clipboard access. Sync manually or reopen this app to send.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isSending ? null : _sendCurrentClipboard,
                      icon: _isSending 
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary))
                        : const Icon(Icons.send),
                      label: Text(_isSending ? 'Sending...' : 'Send Clipboard Now'),
                    ),
                  ),
                ],
              ),
            ),

            if (waitingOffers.isNotEmpty) ...[
              Text('Waiting Offer',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 8),
              ...waitingOffers.map((offer) {
                final offerId = offer['offerId']?.toString() ?? 'Unknown';
                final shortId = offerId.length > 8
                    ? '${offerId.substring(0, 4)}...${offerId.substring(offerId.length - 2)}'
                    : offerId;
                final size = _formatSize(offer['byteSize'] as int? ?? 0);

                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(Icons.content_paste,
                                    color: theme.colorScheme.onPrimaryContainer,
                                    size: 20),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(shortId,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                              color:
                                                  theme.colorScheme.onSurface)),
                                  Text('$size • Just now',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              color: theme.colorScheme
                                                  .onSurfaceVariant)),
                                ],
                              ),
                            ],
                          ),
                          Icon(Icons.verified_user,
                              color: theme.colorScheme.primary, size: 20),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => _fetchOffer(offer),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                              child: const Text('Receive',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                final hiddenOfferId =
                                    offer['offerId']?.toString();
                                if (hiddenOfferId == null ||
                                    hiddenOfferId.isEmpty) {
                                  return;
                                }
                                setState(() {
                                  _hiddenOfferIds.add(hiddenOfferId);
                                  _offers.removeWhere(
                                    (candidate) =>
                                        candidate['offerId']?.toString() ==
                                        hiddenOfferId,
                                  );
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: theme.colorScheme.onSurface,
                                side: BorderSide(
                                    color: theme.colorScheme.outline),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                              child: const Text('Hide',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ] else ...[
              Text('Waiting Offer',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text('No waiting offers',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
              const SizedBox(height: 24),
            ],
            Text('History',
                style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  'Clipboard history is not available from the daemon yet.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
