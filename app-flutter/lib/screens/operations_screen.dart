import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';

class OperationsScreen extends StatefulWidget {
  const OperationsScreen({super.key});

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen> {
  String _activeFilter = 'All Ops';

  final List<String> _filters = [
    'All Ops',
    'Completed',
    'Failed',
    'In Progress',
  ];

  List<Map<String, dynamic>> _operations = [];
  bool _isLoading = true;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _transitionSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOperations();
      _subscribeToTransitions();
    });
  }

  @override
  void dispose() {
    _transitionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadOperations() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();
    try {
      final result = await client.listOperations();
      if (mounted) {
        setState(() {
          _operations = List<Map<String, dynamic>>.from(result['operations'] ?? []);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _subscribeToTransitions() {
    final client = context.read<JsonRpcRiftClient>();
    _transitionSub = client.onOperationTransition.listen((event) {
      // In a real implementation we would update the specific operation
      // or just reload the list.
      _loadOperations();
    });
  }

  String _mapStateToStatus(String state) {
    switch (state) {
      case 'Done':
      case 'Completed':
        return 'Completed';
      case 'Failed':
      case 'Error':
        return 'Failed';
      case 'Created':
      case 'Pending':
        return 'Pending';
      default:
        return 'In Progress';
    }
  }

  IconData _mapTypeToIcon(String type) {
    if (type.contains('clipboard')) return Icons.content_copy;
    if (type.contains('pairing')) return Icons.sync;
    if (type.contains('presence')) return Icons.visibility;
    return Icons.terminal;
  }

  Widget _buildLegendItem(String label, Color color, ThemeData theme, {bool isOutlined = false, bool isBold = false}) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isOutlined ? theme.colorScheme.surface : color.withValues(alpha: 0.15),
        border: Border.all(color: isOutlined ? theme.colorScheme.outlineVariant : color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: isOutlined ? theme.colorScheme.onSurface : color,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, ThemeData theme) {
    final isActive = _activeFilter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () {
          setState(() {
            _activeFilter = label;
          });
        },
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: isActive ? theme.colorScheme.primary : theme.colorScheme.surface,
            border: Border.all(
              color: isActive ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperationCard({
    required ThemeData theme,
    required String name,
    required String opId,
    required String peer,
    required IconData icon,
    required String status,
    required String timeAgo,
    required List<Map<String, String>> timeline,
  }) {
    Color statusColor;
    Color iconBgColor;
    Color iconColor;
    Color borderColor;

    switch (status) {
      case 'Completed':
        statusColor = theme.colorScheme.secondary;
        iconBgColor = theme.colorScheme.secondaryContainer.withValues(alpha: 0.3);
        iconColor = theme.colorScheme.secondary;
        borderColor = theme.colorScheme.outlineVariant;
        break;
      case 'Failed':
        statusColor = theme.colorScheme.error;
        iconBgColor = theme.colorScheme.errorContainer.withValues(alpha: 0.5);
        iconColor = theme.colorScheme.error;
        borderColor = theme.colorScheme.error.withValues(alpha: 0.3);
        break;
      case 'In Progress':
        statusColor = theme.colorScheme.primary;
        iconBgColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.3);
        iconColor = theme.colorScheme.primary;
        borderColor = theme.colorScheme.primary.withValues(alpha: 0.5);
        break;
      default:
        statusColor = theme.colorScheme.outline;
        iconBgColor = theme.colorScheme.surfaceContainerHighest;
        iconColor = theme.colorScheme.onSurfaceVariant;
        borderColor = theme.colorScheme.outlineVariant;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      color: status == 'Failed' ? theme.colorScheme.errorContainer.withValues(alpha: 0.1) : theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.all(16),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: iconColor.withValues(alpha: 0.2)),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            opId,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.devices, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            peer,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    status.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                timeAgo,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transition History',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Column(
                      children: timeline.asMap().entries.map((entry) {
                        final index = entry.key;
                        final isLast = index == timeline.length - 1;
                        final state = entry.value['state']!;
                        final time = entry.value['time']!;

                        Color stateColor;
                        switch (state) {
                          case 'Created':
                            stateColor = theme.colorScheme.outline;
                            break;
                          case 'Pending':
                            stateColor = Colors.yellow.shade700;
                            break;
                          case 'In Progress':
                            stateColor = theme.colorScheme.primary;
                            break;
                          case 'Completed':
                            stateColor = theme.colorScheme.secondary;
                            break;
                          case 'Failed':
                            stateColor = theme.colorScheme.error;
                            break;
                          default:
                            stateColor = theme.colorScheme.outline;
                        }

                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Column(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: stateColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: theme.colorScheme.surfaceContainerLowest, width: 2),
                                    ),
                                  ),
                                  if (!isLast)
                                    Expanded(
                                      child: Container(
                                        width: 2,
                                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        state,
                                        style: theme.textTheme.labelMedium?.copyWith(
                                          color: isLast ? stateColor : theme.colorScheme.onSurface,
                                          fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                      Text(
                                        time,
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: () {},
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurface,
                        side: BorderSide(color: theme.colorScheme.outlineVariant),
                      ),
                      child: const Text('View Full Payload'),
                    ),
                  ),
                ],
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

    List<Map<String, dynamic>> filteredOps = _operations;
    if (_activeFilter != 'All Ops') {
      filteredOps = _operations.where((op) {
        final status = _mapStateToStatus(op['state']?.toString() ?? '');
        return status == _activeFilter;
      }).toList();
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,

      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Operations', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
                  const SizedBox(height: 16),
                  // Legend
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STATE TRANSITION LEGEND',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _buildLegendItem('Created', theme.colorScheme.outline, theme, isOutlined: true),
                              const Icon(Icons.arrow_right, color: Colors.grey, size: 20),
                              _buildLegendItem('Pending', Colors.yellow.shade700, theme, isOutlined: true),
                              const Icon(Icons.arrow_right, color: Colors.grey, size: 20),
                              _buildLegendItem('In Progress', theme.colorScheme.primary, theme, isBold: true),
                              const Icon(Icons.arrow_right, color: Colors.grey, size: 20),
                              _buildLegendItem('Completed', theme.colorScheme.secondary, theme),
                              _buildLegendItem('Failed', theme.colorScheme.error, theme),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Filters
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _filters.map((f) => _buildFilterChip(f, theme)).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            sliver: _isLoading 
                ? const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  )
                : _error != null && _operations.isEmpty
                    ? SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Column(
                              children: [
                                Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                                const SizedBox(height: 16),
                                Text('Failed to load operations:', style: theme.textTheme.titleMedium),
                                Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error), textAlign: TextAlign.center),
                              ],
                            ),
                          ),
                        ),
                      )
                    : filteredOps.isEmpty
                        ? SliverToBoxAdapter(
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(48.0),
                                child: Text('No operations found.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                              ),
                            ),
                          )
                        : SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final op = filteredOps[index];
                                final opId = op['operationId']?.toString() ?? 'unknown';
                                final shortId = opId.length > 8 ? 'op_${opId.substring(0, 4)}' : opId;
                                final status = _mapStateToStatus(op['state']?.toString() ?? '');
                                
                                return _buildOperationCard(
                                  theme: theme,
                                  name: op['operationType']?.toString() ?? 'unknown',
                                  opId: shortId,
                                  peer: op['destinationDeviceId']?.toString() ?? op['sourceDeviceId']?.toString() ?? 'unknown',
                                  icon: _mapTypeToIcon(op['operationType']?.toString() ?? ''),
                                  status: status,
                                  timeAgo: 'recently', // We could parse createdAt here
                                  timeline: [
                                    {'state': status, 'time': op['updatedAt']?.toString() ?? ''}
                                  ], // Mock timeline for now unless getOperation is called
                                );
                              },
                              childCount: filteredOps.length,
                            ),
                          ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}
