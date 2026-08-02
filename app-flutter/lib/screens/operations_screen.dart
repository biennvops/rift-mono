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
    'In Progress',
    'Pending',
    'Completed',
    'Failed',
  ];

  List<Map<String, dynamic>> _operations = [];
  bool _isLoading = true;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _transitionSub;

  static const Color _successColor = Color(0xFF059669);
  static const Color _successBg = Color(0x1A059669);
  static const Color _pendingColor = Color(0xFF6366F1);
  static const Color _pendingBg = Color(0x1A6366F1);

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
          _operations =
              List<Map<String, dynamic>>.from(result['operations'] ?? []);
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
    _transitionSub = client.onOperationTransition.listen((_) {
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
        return 'Pending';
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

  Widget _buildLegendItem(
    String label,
    Color color,
    ThemeData theme, {
    bool isOutlined = false,
    bool isBold = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: isOutlined
              ? theme.colorScheme.outlineVariant
              : color.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(4),
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

  Widget _buildFilterTab(String label, ThemeData theme) {
    final isActive = _activeFilter == label;
    final primaryColor = theme.colorScheme.primary;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _activeFilter = label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isActive ? primaryColor : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isActive ? primaryColor : onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
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
        statusColor = _successColor;
        iconBgColor = _successBg;
        iconColor = _successColor;
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
        iconBgColor =
            theme.colorScheme.primaryContainer.withValues(alpha: 0.15);
        iconColor = theme.colorScheme.primary;
        borderColor = theme.colorScheme.primary.withValues(alpha: 0.4);
        break;
      case 'Pending':
        statusColor = _pendingColor;
        iconBgColor = _pendingBg;
        iconColor = _pendingColor;
        borderColor = theme.colorScheme.outlineVariant;
        break;
      default:
        statusColor = theme.colorScheme.outline;
        iconBgColor = Colors.white;
        iconColor = theme.colorScheme.onSurfaceVariant;
        borderColor = theme.colorScheme.outlineVariant;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(
          dividerColor: Colors.transparent,
          splashColor: theme.colorScheme.primary.withValues(alpha: 0.08),
          highlightColor: theme.colorScheme.primary.withValues(alpha: 0.04),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.all(16),
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        status.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.03,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    timeAgo,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.expand_more,
                size: 20,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: iconColor.withValues(alpha: 0.2)),
                ),
                child: Icon(icon, color: iconColor, size: 20),
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
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
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
                        Icon(Icons.devices,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            peer,
                            style: theme.textTheme.bodySmall?.copyWith(
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
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TRANSITION HISTORY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.05,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
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
                            stateColor = _pendingColor;
                            break;
                          case 'In Progress':
                            stateColor = theme.colorScheme.primary;
                            break;
                          case 'Completed':
                            stateColor = _successColor;
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
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: stateColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                  if (!isLast)
                                    Expanded(
                                      child: Container(
                                        width: 2,
                                        color: theme.colorScheme.outlineVariant
                                            .withValues(alpha: 0.3),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        state,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: isLast
                                              ? stateColor
                                              : theme.colorScheme.onSurface,
                                          fontWeight: isLast
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                      Text(
                                        time,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
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
                  const SizedBox(height: 8),
                  Container(
                    height: 1,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        textStyle: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
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
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Operations',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                      letterSpacing: -0.01,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STATE TRANSITION LEGEND',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.05,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _buildLegendItem(
                                  'Created', theme.colorScheme.outline, theme,
                                  isOutlined: true),
                              const Icon(Icons.arrow_right,
                                  color: Colors.grey, size: 16),
                              _buildLegendItem('Pending', _pendingColor, theme,
                                  isOutlined: true),
                              const Icon(Icons.arrow_right,
                                  color: Colors.grey, size: 16),
                              _buildLegendItem('In Progress',
                                  theme.colorScheme.primary, theme,
                                  isBold: true),
                              const Icon(Icons.arrow_right,
                                  color: Colors.grey, size: 16),
                              _buildLegendItem(
                                  'Completed', _successColor, theme),
                              _buildLegendItem(
                                  'Failed', theme.colorScheme.error, theme),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _filters
                            .map((f) => _buildFilterTab(f, theme))
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            sliver: _isLoading
                ? SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                : _error != null && _operations.isEmpty
                    ? SliverToBoxAdapter(
                        child: Container(
                          key: const ValueKey('operations-load-error-card'),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            vertical: 24,
                            horizontal: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.error_outline,
                                  size: 28,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Failed to load operations',
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      )
                    : filteredOps.isEmpty
                        ? SliverToBoxAdapter(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                vertical: 64,
                                horizontal: 24,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.inbox_outlined,
                                    size: 40,
                                    color: theme.colorScheme.outline
                                        .withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No operations found.',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final op = filteredOps[index];
                                final opId =
                                    op['operationId']?.toString() ?? 'unknown';
                                final shortId = opId.length > 8
                                    ? 'op_${opId.substring(0, 4)}'
                                    : opId;
                                final status = _mapStateToStatus(
                                    op['state']?.toString() ?? '');

                                return _buildOperationCard(
                                  theme: theme,
                                  name: op['operationType']?.toString() ??
                                      'unknown',
                                  opId: shortId,
                                  peer: op['destinationDeviceId']?.toString() ??
                                      op['sourceDeviceId']?.toString() ??
                                      'unknown',
                                  icon: _mapTypeToIcon(
                                      op['operationType']?.toString() ?? ''),
                                  status: status,
                                  timeAgo: 'recently',
                                  timeline: [
                                    {
                                      'state': status,
                                      'time': op['updatedAt']?.toString() ?? '',
                                    },
                                  ],
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
