import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../src/clipboard/desktop_clipboard_manager.dart';
import '../../src/file_transfer/file_storage.dart';
import '../../src/ipc/json_rpc_client.dart';
import '../../widgets/rift_snackbar.dart';

class ClipboardHistoryView extends StatefulWidget {
  const ClipboardHistoryView({super.key});

  @override
  State<ClipboardHistoryView> createState() => _ClipboardHistoryViewState();
}

class _ClipboardHistoryViewState extends State<ClipboardHistoryView> {
  final Set<String> _filteredSourceDeviceIds = {};
  final Set<String> _filteredTypes = {};
  final List<Map<String, dynamic>> _daemonOffers = <Map<String, dynamic>>[];
  final Map<String, String> _trustedPeerNames = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadClipboardHistory();
    });
  }

  Future<void> _loadClipboardHistory() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final offersResult = await client.listClipboardOffers();
      final peersResult = await client.listTrustedPeers();
      if (!mounted) {
        return;
      }

      setState(() {
        _daemonOffers
          ..clear()
          ..addAll(
            List<Map<String, dynamic>>.from(
              (offersResult['offers'] as List? ?? const <dynamic>[])
                  .map((item) => Map<String, dynamic>.from(item as Map)),
            ),
          );
        _trustedPeerNames
          ..clear()
          ..addEntries(
            List<Map<String, dynamic>>.from(
              (peersResult['peers'] as List? ?? const <dynamic>[])
                  .map((item) => Map<String, dynamic>.from(item as Map)),
            ).map((peer) {
              final deviceId = peer['deviceId']?.toString() ?? '';
              final displayName = peer['displayName']?.toString() ?? '';
              return MapEntry(
                deviceId,
                displayName.isNotEmpty ? displayName : deviceId,
              );
            }).where((entry) => entry.key.isNotEmpty),
          );
      });
    } catch (_) {}
  }

  String _sourceLabel(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return 'Unknown Device';
    }
    return _trustedPeerNames[deviceId] ?? deviceId;
  }

  List<Map<String, dynamic>> _getSortedOffers(
      DesktopClipboardManager? manager) {
    final offers = manager != null && manager.activeOffers.isNotEmpty
        ? manager.activeOffers.values.toList(growable: false)
        : _daemonOffers;
    return List<Map<String, dynamic>>.from(offers)
      ..sort((a, b) {
        final expA = DateTime.tryParse(a['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final expB = DateTime.tryParse(b['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return expB.compareTo(expA);
      });
  }

  List<MapEntry<String?, int>> _computeSourceEntries(
      List<Map<String, dynamic>> offers) {
    final counts = <String?, int>{};
    for (final o in offers) {
      final src = _sourceLabel(o['sourceDeviceId']?.toString());
      counts[src] = (counts[src] ?? 0) + 1;
    }
    return counts.entries.toList(growable: false);
  }

  List<MapEntry<String, int>> _computeTypeEntries(
      List<Map<String, dynamic>> offers) {
    final counts = <String, int>{};
    for (final o in offers) {
      final mediaType =
          o['contentType']?.toString() ?? 'application/octet-stream';
      final typeLabel = mediaType.startsWith('text/') ? 'TEXT' : 'FILE';
      counts[typeLabel] = (counts[typeLabel] ?? 0) + 1;
    }
    return counts.entries.toList(growable: false);
  }

  List<Map<String, dynamic>> _filterOffers(List<Map<String, dynamic>> offers) {
    return offers.where((o) {
      final src = _sourceLabel(o['sourceDeviceId']?.toString());
      if (_filteredSourceDeviceIds.isNotEmpty &&
          !_filteredSourceDeviceIds.contains(src)) {
        return false;
      }
      final mediaType =
          o['contentType']?.toString() ?? 'application/octet-stream';
      final typeLabel = mediaType.startsWith('text/') ? 'TEXT' : 'FILE';
      if (_filteredTypes.isNotEmpty && !_filteredTypes.contains(typeLabel)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manager = context.watch<DesktopClipboardManager?>();
    final allOffers = _getSortedOffers(manager);
    final sourceEntries = _computeSourceEntries(allOffers);
    final typeEntries = _computeTypeEntries(allOffers);
    final visibleOffers = _filterOffers(allOffers);
    final totalSources = sourceEntries.length;
    final totalTypes = typeEntries.length;

    final totalBytes = visibleOffers.fold<num>(
      0,
      (sum, o) => sum + (o['byteSize'] as num? ?? 0),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildToolbar(
            theme,
            totalSources,
            totalTypes,
            visibleOffers.length,
            totalBytes,
            sourceEntries,
            typeEntries,
          ),
          const SizedBox(height: 24),
          if (visibleOffers.isEmpty)
            _buildEmptyState(theme, allOffers.isEmpty)
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleOffers.length,
              separatorBuilder: (context, index) => const SizedBox(height: 16),
              itemBuilder: (context, index) =>
                  _buildClipboardOfferCard(theme, visibleOffers[index]),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar(
    ThemeData theme,
    int totalSources,
    int totalTypes,
    int visibleCount,
    num totalBytes,
    List<MapEntry<String?, int>> sourceEntries,
    List<MapEntry<String, int>> typeEntries,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildDeviceFilterMenu(theme, totalSources, sourceEntries),
                _buildTypeFilterMenu(theme, totalTypes, typeEntries),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment:
                  isMobile ? MainAxisAlignment.start : MainAxisAlignment.end,
              children: [
                _buildStatItem(theme, '$visibleCount', 'ITEMS'),
                const SizedBox(width: 32),
                _buildStatItem(theme, _formatSize(totalBytes), 'TOTAL SIZE'),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatItem(ThemeData theme, String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme, bool noOffersAtAll) {
    return Container(
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
          Icon(
            Icons.content_paste_off_outlined,
            size: 48,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            noOffersAtAll
                ? 'No clipboard items yet.'
                : 'No items match filters.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceFilterMenu(ThemeData theme, int totalSources,
      List<MapEntry<String?, int>> sourceEntries) {
    final activeCount = _filteredSourceDeviceIds.isEmpty
        ? 0
        : _filteredSourceDeviceIds.where((id) => id != '__none__').length;
    final label = _filteredSourceDeviceIds.isEmpty
        ? 'All devices'
        : '$activeCount of $totalSources';

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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              if (activeCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$activeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
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
            'SOURCE DEVICE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        if (sourceEntries.isEmpty)
          MenuItemButton(
            onPressed: null,
            style: MenuItemButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              minimumSize: const Size(220, 44),
            ),
            child: const Text('No connected devices'),
          )
        else
          ...sourceEntries.map((entry) {
            final deviceId = entry.key;
            final count = entry.value;
            final isSelected = _filteredSourceDeviceIds.isEmpty ||
                (deviceId != null &&
                    _filteredSourceDeviceIds.contains(deviceId));

            return MenuItemButton(
              style: MenuItemButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                minimumSize: const Size(220, 40),
              ),
              closeOnActivate: false,
              onPressed: () => _toggleDeviceFilter(deviceId),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleDeviceFilter(deviceId),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${deviceId ?? 'Unknown'} ($count)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildTypeFilterMenu(ThemeData theme, int totalTypes,
      List<MapEntry<String, int>> typeEntries) {
    final activeCount = _filteredTypes.isEmpty
        ? 0
        : _filteredTypes.where((t) => t != '__none__').length;
    final label =
        _filteredTypes.isEmpty ? 'All types' : '$activeCount of $totalTypes';

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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              if (activeCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$activeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
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
            'CONTENT TYPE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        if (typeEntries.isEmpty)
          MenuItemButton(
            onPressed: null,
            style: MenuItemButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              minimumSize: const Size(220, 44),
            ),
            child: const Text('No types available'),
          )
        else
          ...typeEntries.map((entry) {
            final typeLabel = entry.key;
            final count = entry.value;
            final isSelected =
                _filteredTypes.isEmpty || _filteredTypes.contains(typeLabel);

            return MenuItemButton(
              style: MenuItemButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                minimumSize: const Size(220, 40),
              ),
              closeOnActivate: false,
              onPressed: () => _toggleTypeFilter(typeLabel),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleTypeFilter(typeLabel),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$typeLabel ($count)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildClipboardOfferCard(ThemeData theme, Map<String, dynamic> offer) {
    final mediaType =
        offer['contentType']?.toString() ?? 'application/octet-stream';
    final sourceDeviceId = offer['sourceDeviceId']?.toString();
    final sizeLabel = _formatSize(offer['byteSize'] as num? ?? 0);
    final expiresAt = DateTime.tryParse(offer['expiresAt']?.toString() ?? '');
    final isExpired = expiresAt != null && expiresAt.isBefore(DateTime.now());
    final isText = mediaType.startsWith('text/');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 480;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.devices_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _sourceLabel(sourceDeviceId),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isText
                          ? theme.colorScheme.surfaceContainerHigh
                          : theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isText ? 'TEXT' : 'FILE',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: isText
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (isText)
                Text(
                  'Encrypted text clip ready to fetch',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                )
              else
                Container(
                  width: double.infinity,
                  height: 100,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.insert_drive_file,
                    size: 32,
                    color: theme.colorScheme.outline,
                  ),
                ),
              const SizedBox(height: 16),
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              if (isMobile)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatusAndSize(theme, isExpired, sizeLabel),
                    const SizedBox(height: 12),
                    _buildActionButtons(theme, isText, offer),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildStatusAndSize(theme, isExpired, sizeLabel),
                    _buildActionButtons(theme, isText, offer),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusAndSize(
    ThemeData theme,
    bool isExpired,
    String sizeLabel,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isExpired ? Icons.access_time : Icons.check_circle,
          size: 16,
          color:
              isExpired ? theme.colorScheme.outline : theme.colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Text(
          isExpired ? 'Expired' : 'Auto-synced',
          style: theme.textTheme.labelMedium?.copyWith(
            color: isExpired
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          ' • $sizeLabel',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(
      ThemeData theme, bool isText, Map<String, dynamic> offer) {
    return Wrap(
      spacing: 8,
      children: [
        TextButton.icon(
          onPressed: () => _copyOffer(offer),
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minimumSize: const Size(0, 36),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        if (!isText)
          TextButton.icon(
            onPressed: () => _saveOffer(offer),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Save'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _copyOffer(Map<String, dynamic> offer) async {
    final manager = context.read<DesktopClipboardManager?>();
    if (manager == null) {
      RiftSnackbar.show(
        context: context,
        message: 'Clipboard manager not available.',
        type: RiftSnackbarType.error,
      );
      return;
    }

    final offerId = offer['offerId']?.toString();
    if (offerId == null) return;

    RiftSnackbar.show(
      context: context,
      message: 'Fetching clipboard content...',
      type: RiftSnackbarType.info,
      duration: const Duration(seconds: 2),
    );

    final success = await manager.fetchAndApplyOffer(offerId);
    if (!mounted) return;

    if (success) {
      RiftSnackbar.show(
        context: context,
        message: 'Copied to clipboard!',
        type: RiftSnackbarType.success,
      );
    } else {
      RiftSnackbar.show(
        context: context,
        message: 'Failed to copy clipboard content or offer expired.',
        type: RiftSnackbarType.error,
      );
    }
  }

  Future<void> _saveOffer(Map<String, dynamic> offer) async {
    final manager = context.read<DesktopClipboardManager?>();
    if (manager == null) {
      RiftSnackbar.show(
        context: context,
        message: 'Clipboard manager not available.',
        type: RiftSnackbarType.error,
      );
      return;
    }

    final offerId = offer['offerId']?.toString();
    if (offerId == null) return;

    RiftSnackbar.show(
      context: context,
      message: 'Downloading clipboard item...',
      type: RiftSnackbarType.info,
      duration: const Duration(seconds: 2),
    );

    final payload = await manager.fetchOfferPayload(offerId);
    if (!mounted) return;

    if (payload == null) {
      RiftSnackbar.show(
        context: context,
        message: 'Failed to download clipboard item or offer expired.',
        type: RiftSnackbarType.error,
      );
      return;
    }

    final fileName = offer['fileName']?.toString() ??
        (payload.contentType == 'image/png'
            ? 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png'
            : 'clipboard_${DateTime.now().millisecondsSinceEpoch}.bin');
    final savePath = await buildDefaultIncomingFilePath(fileName);
    if (!mounted) return;

    if (savePath == null) {
      RiftSnackbar.show(
        context: context,
        message: 'Could not access download directory.',
        type: RiftSnackbarType.error,
      );
      return;
    }

    try {
      await File(savePath).writeAsBytes(payload.bytes);
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Saved to $fileName',
        type: RiftSnackbarType.success,
      );
    } catch (e) {
      if (!mounted) return;
      RiftSnackbar.show(
        context: context,
        message: 'Failed to save file: $e',
        type: RiftSnackbarType.error,
      );
    }
  }

  void _toggleDeviceFilter(String? deviceId) {
    if (deviceId == null) return;
    setState(() {
      if (_filteredSourceDeviceIds.contains(deviceId)) {
        _filteredSourceDeviceIds.remove(deviceId);
      } else {
        _filteredSourceDeviceIds.add(deviceId);
      }
    });
  }

  void _toggleTypeFilter(String typeLabel) {
    setState(() {
      if (_filteredTypes.contains(typeLabel)) {
        _filteredTypes.remove(typeLabel);
      } else {
        _filteredTypes.add(typeLabel);
      }
    });
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
