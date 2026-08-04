import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../src/file_transfer/file_storage.dart';
import '../../src/ipc/json_rpc_client.dart';
import '../../widgets/rift_snackbar.dart';

class IncomingOffersView extends StatefulWidget {
  const IncomingOffersView({
    super.key,
    this.buildDestinationPathOverride,
    this.onOffersChanged,
  });

  final Future<String?> Function(String fileName)? buildDestinationPathOverride;
  final VoidCallback? onOffersChanged;

  @override
  State<IncomingOffersView> createState() => _IncomingOffersViewState();
}

class _IncomingOffersViewState extends State<IncomingOffersView> {
  final Set<String> _selectedIncomingOffers = {};
  final Set<String> _expandedHashOffers = {};
  final Set<String> _busyOffers = {};

  final List<Map<String, dynamic>> _incomingFileOffers = [];
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final client = context.read<JsonRpcRiftClient>();
    _subscriptions
      ..add(client.onFileOffer.listen((_) => _load()))
      ..add(client.onFileTransferCompleted.listen((_) => _load()))
      ..add(client.onFileTransferFailed.listen((_) => _load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final result =
          await context.read<JsonRpcRiftClient>().listIncomingFileOffers();
      final offers = List<Map<String, dynamic>>.from(
        result['offers'] as List? ?? const <dynamic>[],
      );
      if (!mounted) return;
      setState(() {
        _incomingFileOffers
          ..clear()
          ..addAll(offers);
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

  Future<void> _accept(Map<String, dynamic> offer) async {
    final transferId = offer['transferId']?.toString() ?? '';
    final fileName = offer['fileName']?.toString() ?? 'incoming.bin';
    if (transferId.isEmpty) return;
    final client = context.read<JsonRpcRiftClient>();
    final destinationPath = await (widget.buildDestinationPathOverride ??
            buildDefaultIncomingFilePath)
        .call(fileName);
    if (destinationPath == null) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: 'No download destination is available.',
          type: RiftSnackbarType.error,
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busyOffers.add(transferId));
    try {
      await client.acceptFileOffer(
        transferId: transferId,
        destinationPath: destinationPath,
      );
      if (!mounted) return;
      setState(() {
        _incomingFileOffers
            .removeWhere((item) => item['transferId'] == transferId);
        _selectedIncomingOffers.remove(transferId);
      });
      widget.onOffersChanged?.call();
    } catch (error) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(error),
          type: RiftSnackbarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busyOffers.remove(transferId));
    }
  }

  Future<void> _reject(Map<String, dynamic> offer) async {
    final transferId = offer['transferId']?.toString() ?? '';
    if (transferId.isEmpty) return;
    setState(() => _busyOffers.add(transferId));
    try {
      await context.read<JsonRpcRiftClient>().rejectFileOffer(
            transferId: transferId,
            failureReason: 'PolicyDenied',
            message: 'User declined incoming file transfer.',
          );
      if (!mounted) return;
      setState(() {
        _incomingFileOffers
            .removeWhere((item) => item['transferId'] == transferId);
        _selectedIncomingOffers.remove(transferId);
      });
      widget.onOffersChanged?.call();
    } catch (error) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: JsonRpcRiftClient.formatDisplayError(error),
          type: RiftSnackbarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busyOffers.remove(transferId));
    }
  }

  Future<void> _applySelected(bool accept) async {
    final selected = _incomingFileOffers
        .where((offer) =>
            _selectedIncomingOffers.contains(offer['transferId']?.toString()))
        .toList();
    for (final offer in selected) {
      if (accept) {
        await _accept(offer);
      } else {
        await _reject(offer);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offers = _incomingFileOffers;

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isLoading && offers.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_loadError != null && offers.isEmpty)
              _buildLoadError(theme)
            else if (offers.isEmpty)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
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
                        border:
                            Border.all(color: theme.colorScheme.outlineVariant),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.move_to_inbox,
                          size: 20, color: theme.colorScheme.secondary),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No incoming offers',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              _buildIncomingOffersBulkBar(theme, offers),
              const SizedBox(height: 10),
              ...offers.map((offer) => _buildIncomingOfferCard(theme, offer)),
            ],
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
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildIncomingOffersBulkBar(
      ThemeData theme, List<Map<String, dynamic>> offers) {
    final allSelected =
        offers.isNotEmpty && _selectedIncomingOffers.length == offers.length;
    final anySelected = _selectedIncomingOffers.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Checkbox(
            tristate: true,
            value: !anySelected ? false : (allSelected ? true : null),
            fillColor: WidgetStateProperty.resolveWith((states) {
              if (!anySelected) return null;
              return allSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.primary.withValues(alpha: 0.5);
            }),
            checkColor: theme.colorScheme.onPrimary,
            onChanged: (val) {
              setState(() {
                if (val == true || val == null) {
                  _selectedIncomingOffers.addAll(
                    offers
                        .map((o) => o['transferId']?.toString() ?? '')
                        .where((id) => id.isNotEmpty),
                  );
                } else {
                  _selectedIncomingOffers.clear();
                }
              });
            },
          ),
          const SizedBox(width: 8),
          Text(
            '${_selectedIncomingOffers.length} selected',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          if (anySelected) ...[
            const Spacer(),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _applySelected(true),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text(
                    'Accept Selected',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _applySelected(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                      color: !anySelected
                          ? theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.3)
                          : theme.colorScheme.error,
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text(
                    'Reject Selected',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIncomingOfferCard(ThemeData theme, Map<String, dynamic> offer) {
    final transferId = offer['transferId']?.toString() ?? '';
    final sourceDeviceId =
        offer['sourceDeviceId']?.toString() ?? 'Unknown Device';
    final fileName = offer['fileName']?.toString() ?? 'Unknown file';
    final byteSize = (offer['byteSize'] as num?)?.toDouble() ?? 0;
    final mediaType =
        offer['mediaType']?.toString() ?? 'application/octet-stream';
    final isSelected = _selectedIncomingOffers.contains(transferId);
    final isExpanded = _expandedHashOffers.contains(transferId);
    final hashStr = offer['fileHash']?.toString() ??
        offer['sha256']?.toString() ??
        offer['hash']?.toString();
    final hasHash = hashStr != null && hashStr.trim().isNotEmpty;
    final isBusy = _busyOffers.contains(transferId);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;

        return Flex(
          direction: isMobile ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              isMobile ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            Flexible(
              fit: isMobile ? FlexFit.loose : FlexFit.tight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedIncomingOffers.add(transferId);
                        } else {
                          _selectedIncomingOffers.remove(transferId);
                        }
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_formatSize(byteSize)} • from $sourceDeviceId • ${mediaType.split('/').last.toUpperCase()}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (hasHash) ...[
                          InkWell(
                            onTap: () {
                              setState(() {
                                if (isExpanded) {
                                  _expandedHashOffers.remove(transferId);
                                } else {
                                  _expandedHashOffers.add(transferId);
                                }
                              });
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  isExpanded
                                      ? 'Hide file hash'
                                      : 'Verify file hash',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  isExpanded
                                      ? Icons.arrow_drop_up
                                      : Icons.arrow_drop_down,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                              ],
                            ),
                          ),
                          if (isExpanded) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                'sha256: $hashStr',
                                style: const TextStyle(
                                  fontFamily: 'JetBrains Mono',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (isMobile) const SizedBox(height: 10),
            if (!isMobile) const SizedBox(width: 12),
            SizedBox(
              width: isMobile ? double.infinity : 160,
              child: isMobile
                  ? Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: isBusy ? null : () => _accept(offer),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 36),
                            ),
                            child: const Text('Accept'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: isBusy ? null : () => _reject(offer),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 36),
                            ),
                            child: const Text('Reject'),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          onPressed: isBusy ? null : () => _accept(offer),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            minimumSize: const Size(0, 40),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4)),
                          ),
                          child: const Text('Accept'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: isBusy ? null : () => _reject(offer),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            minimumSize: const Size(0, 40),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4)),
                          ),
                          child: const Text('Reject'),
                        ),
                      ],
                    ),
            ),
          ],
        );
      }),
    );
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
