import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
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
  String _severityFilter = 'all';
  StreamSubscription<Map<String, dynamic>>? _securityEventSub;

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
        _events = _applySeverityFilter(_allEvents);
        _error = null;
      });
    });
  }

  List<dynamic> _applySeverityFilter(List<dynamic> events) {
    if (_severityFilter == 'all') return events;
    return events.where((event) {
      if (event is! Map) return false;
      return event['severity']?.toString() == _severityFilter;
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
      final result = await client.queryEventLog(
        limit: 100,
        severities: null,
      );
      if (!mounted) return;
      setState(() {
        _allEvents = List<dynamic>.from(result['events'] ?? const []);
        _events = _applySeverityFilter(_allEvents);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _allEvents = [];
        _events = [];
        _loading = false;
        _error = JsonRpcRiftClient.formatDisplayError(e);
      });
    }
  }

  Color _severityColor(BuildContext context, String severity) {
    final scheme = Theme.of(context).colorScheme;
    switch (severity) {
      case 'critical':
        return scheme.error;
      case 'error':
        return Colors.deepOrange;
      case 'warning':
        return Colors.amber.shade800;
      default:
        return scheme.primary;
    }
  }

  String _formatTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return 'Unknown time';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    final mm = parsed.month.toString().padLeft(2, '0');
    final dd = parsed.day.toString().padLeft(2, '0');
    final hh = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    final ss = parsed.second.toString().padLeft(2, '0');
    return '${parsed.year}-$mm-$dd $hh:$min:$ss';
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final severity = event['severity']?.toString() ?? 'info';
    final outcome = event['outcome']?.toString() ?? 'unknown';
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final peerDeviceId = event['peerDeviceId']?.toString();
    final failureReason = event['failureReason']?.toString();
    final timestamp = _formatTimestamp(event['timestamp']?.toString());

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    eventType,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(severity),
                  visualDensity: VisualDensity.compact,
                  backgroundColor:
                      _severityColor(context, severity).withValues(alpha: 0.12),
                  side: BorderSide.none,
                  labelStyle: TextStyle(
                    color: _severityColor(context, severity),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Outcome: $outcome'),
            Text('Time: $timestamp'),
            if (peerDeviceId != null && peerDeviceId.isNotEmpty)
              Text('Peer: $peerDeviceId'),
            if (failureReason != null && failureReason.isNotEmpty)
              Text('Reason: $failureReason'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.eventLogTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadEvents,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(value: 'all', label: Text('All')),
                ButtonSegment<String>(value: 'warning', label: Text('Warnings')),
                ButtonSegment<String>(value: 'error', label: Text('Errors')),
              ],
              selected: {_severityFilter},
              onSelectionChanged: (selection) {
                final next = selection.first;
                if (next == _severityFilter) return;
                setState(() {
                  _severityFilter = next;
                  _events = _applySeverityFilter(_allEvents);
                });
                _loadEvents();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Error loading event log: $_error',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _loadEvents,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _events.isEmpty
                        ? RefreshIndicator(
                            onRefresh: _loadEvents,
                            child: ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                SizedBox(height: 180),
                                Center(
                                  child: Text('No security events recorded yet.'),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadEvents,
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: _events.length,
                              itemBuilder: (context, index) {
                                final event = _events[index];
                                if (event is! Map) {
                                  return const SizedBox.shrink();
                                }
                                return _buildEventCard(
                                  Map<String, dynamic>.from(event),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
