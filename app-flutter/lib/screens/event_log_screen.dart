import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';

class EventLogScreen extends StatefulWidget {
  const EventLogScreen({super.key});

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
                existing is! Map ||
                existing['eventId']?.toString() != eventId,
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
    return severity == 'error' ||
        outcome == 'failure' ||
        outcome == 'denied';
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
          return type.startsWith('session');
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
    final isActive = _activeFilter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () {
          setState(() {
            _activeFilter = label;
            _events = _applyFilter(_allEvents);
          });
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: isActive ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerLow,
            border: Border.all(
              color: isActive ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: isActive ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event, ThemeData theme) {
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final outcome = event['outcome']?.toString() ?? 'unknown';
    final timestamp = _formatTimeOnly(event['timestamp']?.toString());
    final peer = event['peerDeviceId']?.toString();
    final reason = event['failureReason']?.toString();

    // Determine category, color, icon
    String category = 'System';
    Color color = theme.colorScheme.outline;
    IconData icon = Icons.info;
    String description = '';

    if (_isErrorEvent(event)) {
      category = 'Error';
      color = theme.colorScheme.error;
      icon = Icons.error;
      description = reason ?? 'Operation failed';
    } else if (_isSecurityEvent(event)) {
      category = 'Security';
      color = theme.colorScheme.error; // Match HTML for security
      icon = Icons.security;
      if (eventType.startsWith('auth')) {
        description = reason ?? 'Authentication check failed';
      } else if (reason != null && reason.isNotEmpty) {
        description = reason;
      } else if (eventType.startsWith('trust')) {
        description = 'Trust state changed for ${peer ?? 'peer'}';
      } else {
        description = 'Trust established with ${peer ?? 'peer'}';
        if (outcome != 'success') description = 'Pairing $outcome';
      }
    } else if (eventType.startsWith('clipboard')) {
      category = 'Clipboard';
      color = theme.colorScheme.primary;
      icon = Icons.content_copy;
      description = 'Offer from ${peer ?? 'peer'}';
    } else if (eventType.startsWith('session')) {
      category = 'Session';
      color = theme.colorScheme.secondary;
      icon = Icons.check_circle;
      description = 'Secure channel opened with ${peer ?? 'peer'}';
    } else {
      category = 'General';
      color = theme.colorScheme.primary;
      icon = Icons.circle;
      description = 'System event recorded';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left color bar
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                ),
              ),
            ),
            // Timeline line & dot
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.only(top: 8),
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '[$timestamp]',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 12, color: color),
                              const SizedBox(width: 4),
                              Text(
                                category,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      eventType,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: category == 'Error' ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
        title: Row(
          children: [
            Icon(Icons.shield, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Event Log',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.settings, color: theme.colorScheme.onSurfaceVariant),
            onPressed: () {},
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), height: 1),
        ),
      ),
      body: Column(
        children: [
          // Filter Chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.9),
              border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _filters.map((f) => _buildFilterChip(f, theme)).toList(),
              ),
            ),
          ),
          // Event List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Error loading event log: $_error', textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            FilledButton(onPressed: _loadEvents, child: const Text('Retry')),
                          ],
                        ),
                      )
                    : displayEvents.isEmpty
                        ? Center(
                            child: Text(
                              'No events recorded.',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadEvents,
                            child: ListView.builder(
                              padding: const EdgeInsets.all(16),
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: displayEvents.length,
                              itemBuilder: (context, index) {
                                return _buildEventCard(Map<String, dynamic>.from(displayEvents[index] as Map), theme);
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
