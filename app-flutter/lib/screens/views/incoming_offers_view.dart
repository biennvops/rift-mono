import 'package:flutter/material.dart';

class IncomingOffersView extends StatefulWidget {
  const IncomingOffersView({super.key});

  @override
  State<IncomingOffersView> createState() => _IncomingOffersViewState();
}

class _IncomingOffersViewState extends State<IncomingOffersView> {
  final Set<String> _selectedIncomingOffers = {};
  final Set<String> _expandedHashOffers = {};

  final List<Map<String, dynamic>> _incomingFileOffers = [];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offers = _incomingFileOffers;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offers.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
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
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.move_to_inbox,
                        size: 24, color: theme.colorScheme.secondary),
                  ),
                  const SizedBox(height: 24),
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
            const SizedBox(height: 24),
            ...offers.map((offer) => _buildIncomingOfferCard(theme, offer)),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          const Spacer(),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton(
                onPressed: !anySelected ? null : () {},
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)),
                ),
                child: const Text(
                  'Accept Selected',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton(
                onPressed: !anySelected ? null : () {},
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(
                    color: !anySelected
                        ? theme.colorScheme.outlineVariant
                            .withValues(alpha: 0.3)
                        : theme.colorScheme.error,
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  minimumSize: const Size(0, 36),
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

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(24),
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
          crossAxisAlignment:
              isMobile ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            Row(
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
                const SizedBox(width: 16),
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
                      const SizedBox(height: 8),
                      Text(
                        '${_formatSize(byteSize)} • from $sourceDeviceId • ${mediaType.split('/').last.toUpperCase()}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
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
            if (isMobile) const SizedBox(height: 24),
            if (!isMobile) const SizedBox(width: 24),
            SizedBox(
              width: isMobile ? double.infinity : 160,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () {},
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                    ),
                    child: const Text('Accept'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
