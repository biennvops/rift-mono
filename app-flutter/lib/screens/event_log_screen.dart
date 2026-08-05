import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';

class EventLogScreen extends StatefulWidget {
  final VoidCallback? onBack;

  const EventLogScreen({super.key, this.onBack});

  @override
  State<EventLogScreen> createState() => _EventLogScreenState();
}

class _EventLogScreenState extends State<EventLogScreen> {
  List<dynamic> _allEvents = [];
  List<dynamic> _events = [];
  bool _loading = true;
  String? _error;
  String _activeFilter = 'All';
  StreamSubscription<Map<String, dynamic>>? _securityEventSub;

  final List<String> _filters = [
    'All',
    'Security',
    'Pairing',
    'Session',
    'Clipboard',
    'Errors',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClient();
      _loadEvents();
    });
  }

  @override
  void dispose() {
    _securityEventSub?.cancel();
    super.dispose();
  }

  void _bindClient() {
    final client = context.read<JsonRpcRiftClient>();
    _securityEventSub = client.onSecurityEvent.listen((event) {
      if (!mounted) return;
      setState(() {
        final eventId = event['eventId']?.toString();
        _allEvents = [
          Map<String, dynamic>.from(event),
          ..._allEvents.where(
            (existing) =>
                existing is! Map || existing['eventId']?.toString() != eventId,
          ),
        ];
        _events = _applyFilter(_allEvents);
        _error = null;
      });
    });
  }

  bool _isSecurityEvent(Map event) {
    final type = event['eventType']?.toString() ?? '';
    final severity = event['severity']?.toString() ?? '';

    return type.startsWith('pairing') ||
        type.startsWith('trust') ||
        type.startsWith('auth') ||
        severity == 'critical' ||
        severity == 'error';
  }

  bool _isErrorEvent(Map event) {
    final severity = event['severity']?.toString() ?? '';
    final outcome = event['outcome']?.toString() ?? '';
    return severity == 'error' || outcome == 'failure' || outcome == 'denied';
  }

  bool _isConnectionEvent(Map event) {
    final type = event['eventType']?.toString() ?? '';
    return type.startsWith('connection.');
  }

  List<dynamic> _applyFilter(List<dynamic> events) {
    if (_activeFilter == 'All') return events;
    return events.where((event) {
      if (event is! Map) return false;
      final type = event['eventType']?.toString() ?? '';

      switch (_activeFilter) {
        case 'Security':
          return _isSecurityEvent(event);
        case 'Pairing':
          return type.startsWith('pairing');
        case 'Session':
          return _isConnectionEvent(event);
        case 'Clipboard':
          return type.startsWith('clipboard');
        case 'Errors':
          return _isErrorEvent(event);
        default:
          return true;
      }
    }).toList();
  }

  Future<void> _loadEvents() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();

    if (!client.isConnected) {
      setState(() {
        _allEvents = [];
        _events = [];
        _loading = false;
        _error = 'Daemon not connected';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await client.queryEventLog(limit: 100);
      if (!mounted) return;
      setState(() {
        _allEvents = List<dynamic>.from(result['events'] ?? const []);
        _events = _applyFilter(_allEvents);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = JsonRpcRiftClient.formatDisplayError(e);
      });
    }
  }

  String _formatTimeOnly(String? raw) {
    if (raw == null || raw.isEmpty) return '--:--';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return '--:--';
    final hh = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    final ss = parsed.second.toString().padLeft(2, '0');
    return '$hh:$min:$ss';
  }

  Widget _buildFilterChip(String label, ThemeData theme) {
    final isSelected = _activeFilter == label;
    final primaryColor = theme.colorScheme.primary;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;

    int badgeCount = 0;
    if (label == 'All') {
      badgeCount = _allEvents.length;
    } else {
      badgeCount = _applyFilterForLabel(_allEvents, label).length;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _activeFilter = label;
            _events = _applyFilterForLabel(_allEvents, _activeFilter);
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          margin: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? primaryColor : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? primaryColor : onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (badgeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 18),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? primaryColor
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Text(
                      badgeCount.toString(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isSelected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<dynamic> _applyFilterForLabel(List<dynamic> events, String filterLabel) {
    if (filterLabel == 'All') return events;
    return events.where((e) {
      if (filterLabel == 'Errors') return _isErrorEvent(e);
      if (filterLabel == 'Security') return _isSecurityEvent(e);
      if (filterLabel == 'Clipboard' || filterLabel == 'Transfer') {
        final type = e['eventType']?.toString() ?? '';
        return type.startsWith('clipboard') || type.startsWith('file');
      }
      if (filterLabel == 'Session') return _isConnectionEvent(e as Map);
      if (filterLabel == 'Pairing') {
        final type = e['eventType']?.toString() ?? '';
        return type.startsWith('pairing');
      }
      return false;
    }).toList();
  }

  String _descriptionForEvent(
    String eventType,
    String? peer,
    Map<String, dynamic> details,
  ) {
    final message = details['message']?.toString();
    if (message != null && message.isNotEmpty) return message;
    final peerSuffix = peer == null || peer.isEmpty ? '' : ' with $peer';

    return switch (eventType) {
      'pairing.attempted' => 'Pairing flow initiated$peerSuffix',
      'pairing.completed' => 'Pairing completed$peerSuffix',
      'pairing.rejected' => 'Pairing rejected$peerSuffix',
      'trust.transitioned' => 'Trust state changed$peerSuffix',
      'trust.removed' => 'Trust removed$peerSuffix',
      'auth.failed' => 'Authentication failed$peerSuffix',
      'auth.identity_proof_failed' =>
        'Identity proof verification failed$peerSuffix',
      'connection.established' => 'Connection established$peerSuffix',
      'connection.rejected' => 'Connection rejected$peerSuffix',
      'connection.lost' => 'Connection lost$peerSuffix',
      'certificate.rotated' => 'Certificate rotated$peerSuffix',
      'capability.negotiated' => 'Capabilities negotiated$peerSuffix',
      'operation.transitioned' => 'Operation state changed$peerSuffix',
      'clipboard.offered' => 'Clipboard offer recorded$peerSuffix',
      'clipboard.fetched' => 'Clipboard content fetched$peerSuffix',
      'clipboard.expired' => 'Clipboard offer expired$peerSuffix',
      'clipboard.offer_replay' => 'Clipboard offer replay rejected$peerSuffix',
      'notification.synced' => 'Notification synchronized$peerSuffix',
      'notification.removed' => 'Notification removed$peerSuffix',
      'notification.actioned' => 'Notification action processed$peerSuffix',
      'message.malformed' => 'Malformed message rejected$peerSuffix',
      'certificate.malformed' => 'Malformed certificate rejected$peerSuffix',
      'policy.denied' => 'Action denied by local policy$peerSuffix',
      _ => 'Event recorded: $eventType',
    };
  }

  String _formatEventMeta(
    Map<String, dynamic> event,
    Map<String, dynamic> details,
  ) {
    final parts = <String>[];
    final peer = event['peerDeviceId']?.toString();
    final outcome = event['outcome']?.toString();
    final operationId = event['operationId']?.toString();
    final failureReason = event['failureReason']?.toString();

    if (peer != null && peer.isNotEmpty) {
      parts.add('peer: ${peer.length > 8 ? peer.substring(0, 8) : peer}');
    }
    if (outcome != null && outcome.isNotEmpty) parts.add('outcome: $outcome');
    if (operationId != null && operationId.isNotEmpty) {
      parts.add('operationId: $operationId');
    }
    if (failureReason != null && failureReason.isNotEmpty) {
      parts.add('failureReason: $failureReason');
    }
    for (final entry in details.entries) {
      parts.add('${entry.key}: ${entry.value}');
    }
    return parts.join(' · ');
  }

  Widget _buildEventCard(
      Map<String, dynamic> event, bool isLast, ThemeData theme) {
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final timestamp = _formatTimeOnly(event['timestamp']?.toString());
    final peer = event['peerDeviceId']?.toString();
    final reason = event['failureReason']?.toString();
    final details = event['details'] is Map
        ? Map<String, dynamic>.from(event['details'] as Map)
        : <String, dynamic>{};

    Color dotColor = theme.colorScheme.outlineVariant;
    if (_isErrorEvent(event)) {
      dotColor = theme.colorScheme.error;
    } else if (_isSecurityEvent(event) || _isConnectionEvent(event)) {
      dotColor = const Color(0xFF10B981);
    } else if (eventType.startsWith('clipboard') ||
        eventType.startsWith('file')) {
      dotColor = theme.colorScheme.primary;
    }

    final description = reason != null && reason.isNotEmpty
        ? reason
        : _descriptionForEvent(eventType, peer, details);
    final meta = _formatEventMeta(event, details);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 4,
                  top: 0,
                  bottom: isLast ? null : 0,
                  height: isLast ? 18 : null,
                  width: 1.5,
                  child: Container(
                    color:
                        theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 13,
                  width: 10,
                  height: 10,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: dotColor, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: null,
                  borderRadius: BorderRadius.circular(8),
                  hoverColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                eventType,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onSurface,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                timestamp,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          meta,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayEvents = _events;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        titleSpacing: widget.onBack != null ? 0 : 16,
        title: Text(
          'Event Log',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children:
                    _filters.map((f) => _buildFilterChip(f, theme)).toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadEvents,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: theme.colorScheme.outlineVariant),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Error loading event log: $_error',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: _loadEvents,
                                  style: FilledButton.styleFrom(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : displayEvents.isEmpty
                          ? SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 64, horizontal: 24),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: theme.colorScheme.outlineVariant),
                                ),
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.event_busy,
                                        size: 48,
                                        color:
                                            theme.colorScheme.outlineVariant),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No events recorded.',
                                      style:
                                          theme.textTheme.bodyLarge?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: theme.colorScheme.outlineVariant),
                                ),
                                child: Column(
                                  children: [
                                    for (int i = 0;
                                        i < displayEvents.length;
                                        i++) ...[
                                      _buildEventCard(
                                        Map<String, dynamic>.from(
                                            displayEvents[i] as Map),
                                        i == displayEvents.length - 1,
                                        theme,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
            ),
          ),
        ],
      ),
    );
  }
}
