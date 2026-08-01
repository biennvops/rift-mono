import 'dart:async';

import 'package:flutter/material.dart';
import '../../src/file_transfer/file_storage.dart';
import '../../widgets/rift_snackbar.dart';
import 'package:provider/provider.dart';

import '../../src/ipc/json_rpc_client.dart';

class TransferActivityView extends StatefulWidget {
  final bool? revealCompletedTransfersInFolderOverride;

  const TransferActivityView({
    super.key,
    this.revealCompletedTransfersInFolderOverride,
  });

  @override
  State<TransferActivityView> createState() => _TransferActivityViewState();
}

class _TransferActivityViewState extends State<TransferActivityView> {
  String? _activityDeviceFilter;
  String? _activityStatusFilter;

  final List<Map<String, dynamic>> _fileTransfers = [];
  final List<Map<String, dynamic>> _peers = [];
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  bool _isLoading = true;
  String? _loadError;

  bool get _revealCompletedTransfersInFolder =>
      widget.revealCompletedTransfersInFolderOverride ?? true;

  @override
  void initState() {
    super.initState();
    final client = context.read<JsonRpcRiftClient>();
    _subscriptions
      ..add(client.onFileTransferProgress.listen((_) => _loadActivity()))
      ..add(client.onFileTransferCompleted.listen((_) => _loadActivity()))
      ..add(client.onFileTransferFailed.listen((_) => _loadActivity()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadActivity();
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _loadActivity() async {
    final client = context.read<JsonRpcRiftClient>();
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final transfersResult = await client.listFileTransfers();
      final peersResult = await client.listTrustedPeers();
      if (!mounted) {
        return;
      }

      setState(() {
        _fileTransfers
          ..clear()
          ..addAll(
            List<Map<String, dynamic>>.from(
              (transfersResult['transfers'] as List? ?? const <dynamic>[])
                  .map((item) => Map<String, dynamic>.from(item as Map)),
            ),
          );
        _peers
          ..clear()
          ..addAll(
            List<Map<String, dynamic>>.from(
              (peersResult['peers'] as List? ?? const <dynamic>[])
                  .map((item) => Map<String, dynamic>.from(item as Map)),
            ),
          );
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = JsonRpcRiftClient.formatDisplayError(error);
      });
    }
  }

  String _peerLabel(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown Device';
    }

    for (final peer in _peers) {
      final map = Map<String, dynamic>.from(peer);
      if (map['deviceId']?.toString() == deviceId) {
        final displayName = map['displayName']?.toString();
        if (displayName != null && displayName.isNotEmpty) {
          return displayName;
        }
      }
    }

    return deviceId;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transfers = _fileTransfers;

    final filteredTransfers = transfers.where((transfer) {
      if (_activityDeviceFilter != null && _activityDeviceFilter!.isNotEmpty) {
        if (transfer['peerDeviceId']?.toString() != _activityDeviceFilter) {
          return false;
        }
      }
      if (_activityStatusFilter != null && _activityStatusFilter!.isNotEmpty) {
        final state = transfer['state']?.toString().toLowerCase() ?? '';
        if (_activityStatusFilter == 'active') {
          if (state != 'active' &&
              state != 'uploading' &&
              state != 'downloading' &&
              state != 'pending' &&
              state != 'dispatched' &&
              state != 'sending') {
            return false;
          }
        } else if (state != _activityStatusFilter) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);

    return RefreshIndicator(
      onRefresh: _loadActivity,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(theme, filteredTransfers.length),
            const SizedBox(height: 10),
            if (_isLoading && transfers.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_loadError != null && transfers.isEmpty)
              _buildLoadError(theme)
            else if (filteredTransfers.isEmpty)
              _buildEmptyState(theme)
            else
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  children: [
                    for (int i = 0; i < filteredTransfers.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.5),
                        ),
                      _buildTransferActivityRowItem(
                          theme, filteredTransfers[i]),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadError(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error),
      ),
      child: Column(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(height: 8),
          Text(_loadError!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _loadActivity,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme, int transferCount) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;

        return Flex(
          direction: isMobile ? Axis.vertical : Axis.horizontal,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment:
              isMobile ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildDeviceFilterMenu(theme),
                _buildStatusFilterMenu(theme),
              ],
            ),
            if (isMobile) const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                text: '$transferCount\n',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
                children: [
                  TextSpan(
                    text: 'TRANSFERS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              textAlign: isMobile ? TextAlign.left : TextAlign.end,
            ),
          ],
        );
      },
    );
  }

  Widget _buildDeviceFilterMenu(ThemeData theme) {
    final label = _activityDeviceFilter ?? 'All devices';

    return MenuAnchor(
      style: MenuStyle(
        minimumSize: const WidgetStatePropertyAll(Size(240, 0)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        elevation: const WidgetStatePropertyAll(4),
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
      ),
      builder: (context, controller, child) {
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            backgroundColor: Colors.white,
            side: BorderSide(
              color: controller.isOpen
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                controller.isOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'TARGET DEVICE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        _buildDeviceMenuItem(theme, null, 'All devices'),
        ..._peers.map((p) {
          final deviceId = p['deviceId']?.toString();
          if (deviceId == null) return const SizedBox.shrink();
          return _buildDeviceMenuItem(
            theme,
            deviceId,
            _peerLabel(deviceId),
          );
        }),
      ],
    );
  }

  Widget _buildDeviceMenuItem(ThemeData theme, String? value, String text) {
    final isSelected = _activityDeviceFilter == value;
    return MenuItemButton(
      style: MenuItemButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(220, 40),
      ),
      onPressed: () => setState(() => _activityDeviceFilter = value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSelected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 18,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusFilterMenu(ThemeData theme) {
    String label = 'All statuses';
    if (_activityStatusFilter == 'active') {
      label = 'Active / Uploading';
    } else if (_activityStatusFilter == 'done') {
      label = 'Done';
    } else if (_activityStatusFilter == 'failed') {
      label = 'Failed';
    } else if (_activityStatusFilter == 'cancelled') {
      label = 'Cancelled';
    }

    return MenuAnchor(
      style: MenuStyle(
        minimumSize: const WidgetStatePropertyAll(Size(240, 0)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        elevation: const WidgetStatePropertyAll(4),
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
      ),
      builder: (context, controller, child) {
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            backgroundColor: Colors.white,
            side: BorderSide(
              color: controller.isOpen
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.filter_alt_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                controller.isOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'STATUS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        _buildStatusMenuItem(theme, null, 'All statuses'),
        _buildStatusMenuItem(theme, 'active', 'Active / Uploading'),
        _buildStatusMenuItem(theme, 'done', 'Done'),
        _buildStatusMenuItem(theme, 'failed', 'Failed'),
        _buildStatusMenuItem(theme, 'cancelled', 'Cancelled'),
      ],
    );
  }

  Widget _buildStatusMenuItem(ThemeData theme, String? value, String text) {
    final isSelected = _activityStatusFilter == value;
    return MenuItemButton(
      style: MenuItemButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(220, 40),
      ),
      onPressed: () => setState(() => _activityStatusFilter = value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSelected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 18,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.swap_horiz,
                size: 20, color: theme.colorScheme.secondary),
          ),
          const SizedBox(height: 12),
          Text(
            'No transfer activity',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferActivityRowItem(
      ThemeData theme, Map<String, dynamic> transfer) {
    final direction = transfer['direction']?.toString() ?? 'unknown';
    final isIncoming = direction == 'incoming';
    final state = transfer['state']?.toString() ?? 'pending';
    final byteSize = (transfer['byteSize'] as num?)?.toDouble() ?? 0;
    final transferred = (transfer['bytesTransferred'] as num?)?.toDouble() ?? 0;
    final destinationPath = transfer['destinationPath']?.toString() ?? '';
    final progress =
        byteSize <= 0 ? null : (transferred / byteSize).clamp(0, 1).toDouble();
    final canOpenDestination = isIncoming &&
        destinationPath.trim().isNotEmpty &&
        state.toLowerCase() == 'done';
    final peerName = _peerLabel(transfer['peerDeviceId']?.toString());
    final fileName = transfer['fileName']?.toString() ?? 'Unknown file';

    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isIncoming
                  ? const Color(0xFF12744F).withValues(alpha: 0.1)
                  : theme.colorScheme.tertiaryContainer.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              isIncoming ? Icons.arrow_downward : Icons.arrow_upward,
              size: 18,
              color: isIncoming
                  ? const Color(0xFF12744F)
                  : theme.colorScheme.tertiary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: isIncoming ? 'Received from ' : 'Sending to ',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                    children: [
                      TextSpan(
                        text: peerName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        fileName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      progress != null && state.toLowerCase() != 'done'
                          ? ' • ${_formatSize(transferred)} / ${_formatSize(byteSize)}'
                          : ' • ${_formatSize(byteSize)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (canOpenDestination) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Saved to: $destinationPath',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_revealCompletedTransfersInFolder)
                        OutlinedButton.icon(
                          onPressed: () => _openDestination(
                            destinationPath,
                            reveal: true,
                          ),
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: const Text('Open Folder',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            minimumSize: const Size(0, 32),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _openDestination(destinationPath),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open File',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: const Size(0, 32),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                    ],
                  ),
                ],
                if (progress != null &&
                    state.toLowerCase() != 'done' &&
                    state.toLowerCase() != 'failed') ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                    ),
                  ),
                ],
                if (transfer['failureReason'] != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    transfer['failureReason'].toString(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _buildTransferStatusBadge(
            theme,
            state.toUpperCase(),
            tone: _transferStateBadgeTone(theme, state),
            foreground: _transferStateBadgeForeground(theme, state),
          ),
        ],
      ),
    );
  }

  Future<void> _openDestination(String path, {bool reveal = false}) async {
    try {
      if (reveal) {
        await showFileInFolder(path);
      } else {
        await openFilePath(path);
      }
    } catch (error) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: error.toString(),
        type: RiftSnackbarType.error,
      );
    }
  }

  Widget _buildTransferStatusBadge(ThemeData theme, String label,
      {required Color tone, required Color foreground}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Color _transferStateBadgeTone(ThemeData theme, String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return theme.colorScheme.secondaryContainer;
      case 'failed':
        return theme.colorScheme.errorContainer;
      case 'active':
      case 'uploading':
      case 'downloading':
      case 'sending':
      case 'dispatched':
        return theme.colorScheme.primaryContainer;
      default:
        return theme.colorScheme.surfaceContainerHighest;
    }
  }

  Color _transferStateBadgeForeground(ThemeData theme, String state) {
    switch (state.toLowerCase()) {
      case 'done':
        return theme.colorScheme.onSecondaryContainer;
      case 'failed':
        return theme.colorScheme.onErrorContainer;
      case 'active':
      case 'uploading':
      case 'downloading':
      case 'sending':
      case 'dispatched':
        return theme.colorScheme.onPrimaryContainer;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  String _formatSize(num rawBytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = rawBytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final formatted = value >= 10 || unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$formatted ${units[unitIndex]}';
  }
}
