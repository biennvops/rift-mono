import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../src/clipboard/desktop_clipboard_manager.dart';
import '../../src/file_transfer/file_storage.dart';
import '../../src/ipc/json_rpc_client.dart';
import '../../src/platform/ios_clipboard.dart';
import '../../widgets/rift_snackbar.dart';

class ClipboardHistoryView extends StatefulWidget {
  final String? preferredSourceDeviceId;
  final int? targetRequestVersion;
  final VoidCallback? onTargetScopeCleared;
  final bool? iosClipboardActionsOverride;
  final Future<IOSClipboardContent?> Function()? readClipboardContentOverride;
  final Future<String?> Function()? readClipboardTextOverride;
  final Future<void> Function(IOSClipboardContent content)?
      writeClipboardContentOverride;
  final Future<void> Function(String text)? writeClipboardTextOverride;

  const ClipboardHistoryView({
    super.key,
    this.preferredSourceDeviceId,
    this.targetRequestVersion,
    this.onTargetScopeCleared,
    this.iosClipboardActionsOverride,
    this.readClipboardContentOverride,
    this.readClipboardTextOverride,
    this.writeClipboardContentOverride,
    this.writeClipboardTextOverride,
  });

  @override
  State<ClipboardHistoryView> createState() => _ClipboardHistoryViewState();
}

class _ClipboardHistoryViewState extends State<ClipboardHistoryView> {
  bool get _iosClipboardActions =>
      widget.iosClipboardActionsOverride ??
      (Platform.isIOS || Platform.isAndroid);
  String? _localDeviceId;
  final Set<String> _filteredSourceDeviceIds = {};
  String? _preferredSourceDeviceId;
  final Set<String> _filteredTypes = {};
  final List<Map<String, dynamic>> _daemonOffers = <Map<String, dynamic>>[];
  final Map<String, String> _trustedPeerNames = <String, String>{};
  final Map<String, String> _trustedPeerPlatforms = <String, String>{};
  final Set<String> _onlinePeerIds = <String>{};
  StreamSubscription<Map<String, dynamic>>? _offerSubscription;
  StreamSubscription<Map<String, dynamic>>? _expiredSubscription;
  StreamSubscription<Map<String, dynamic>>? _trustSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _expiryTicker;

  @override
  void initState() {
    super.initState();
    _applyPreferredSourceDevice();
    final client = context.read<JsonRpcRiftClient>();
    _offerSubscription = client.onClipboardOffer.listen((offer) {
      final offerId = offer['offerId']?.toString();
      if (!mounted || offerId == null || offerId.isEmpty) return;
      final normalizedOffer = _normalizeOffer(offer);
      setState(() {
        _daemonOffers.removeWhere(
          (item) => item['offerId']?.toString() == offerId,
        );
        _daemonOffers.add(normalizedOffer);
      });
      if (_resolvePeerId(offer['sourceDeviceId']?.toString()) == null) {
        unawaited(_loadTrustedPeerMetadata());
      }
    });
    _expiredSubscription = client.onClipboardExpired.listen((event) {
      final offerId = event['offerId']?.toString();
      if (!mounted || offerId == null || offerId.isEmpty) return;
      setState(() {
        _daemonOffers.removeWhere(
          (item) => item['offerId']?.toString() == offerId,
        );
      });
    });
    _trustSubscription = client.onTrustChanged.listen((_) {
      unawaited(_loadTrustedPeerMetadata());
    });
    _connectionSubscription = client.onConnectionChanged.listen((connected) {
      if (connected) unawaited(_loadClipboardHistory());
    });
    _expiryTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(_removeExpiredOffers);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadClipboardHistory();
    });
  }

  @override
  void didUpdateWidget(ClipboardHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetRequestVersion != widget.targetRequestVersion) {
      _applyPreferredSourceDevice();
    }
  }

  void _applyPreferredSourceDevice() {
    final deviceId = widget.preferredSourceDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      _preferredSourceDeviceId = null;
      _filteredSourceDeviceIds.clear();
      return;
    }
    _preferredSourceDeviceId = deviceId;
    _filteredSourceDeviceIds
      ..clear()
      ..add(deviceId);
  }

  @override
  void dispose() {
    _offerSubscription?.cancel();
    _expiredSubscription?.cancel();
    _trustSubscription?.cancel();
    _connectionSubscription?.cancel();
    _expiryTicker?.cancel();
    super.dispose();
  }

  Future<void> _loadClipboardHistory() async {
    await Future.wait([
      _loadClipboardOffers(),
      _loadTrustedPeerMetadata(),
      _loadLocalDeviceInfo(),
    ]);
  }

  Future<void> _loadClipboardOffers() async {
    final client = context.read<JsonRpcRiftClient>();
    try {
      final offersResult = await client.listClipboardOffers();
      if (!mounted) return;
      setState(() {
        _daemonOffers
          ..clear()
          ..addAll(
            List<Map<String, dynamic>>.from(
              (offersResult['offers'] as List? ?? const <dynamic>[])
                  .map((item) => _normalizeOffer(item as Map)),
            ),
          );
        _removeExpiredOffers();
      });
    } catch (_) {}
  }

  Future<void> _loadLocalDeviceInfo() async {
    try {
      final deviceInfoResult =
          await context.read<JsonRpcRiftClient>().getDeviceInfo();
      if (!mounted) return;
      setState(() {
        _localDeviceId = (deviceInfoResult as Map?)?['deviceId']?.toString();
      });
    } catch (_) {}
  }

  Future<void> _loadTrustedPeerMetadata() async {
    try {
      final peersResult =
          await context.read<JsonRpcRiftClient>().listTrustedPeers();
      if (!mounted) return;
      final peers = List<Map<String, dynamic>>.from(
        (peersResult['peers'] as List? ?? const <dynamic>[])
            .map((item) => Map<String, dynamic>.from(item as Map)),
      );
      setState(() {
        _trustedPeerNames
          ..clear()
          ..addEntries(peers.map((peer) {
            final deviceId = peer['deviceId']?.toString() ?? '';
            final displayName = peer['displayName']?.toString() ?? '';
            return MapEntry(deviceId, displayName);
          }).where((entry) => entry.key.isNotEmpty));
        _trustedPeerPlatforms
          ..clear()
          ..addEntries(peers.map((peer) {
            return MapEntry(
              peer['deviceId']?.toString() ?? '',
              peer['platform']?.toString() ?? '',
            );
          }).where((entry) => entry.key.isNotEmpty));
        _onlinePeerIds
          ..clear()
          ..addAll(peers
              .where((peer) =>
                  peer['presence']?.toString().toLowerCase() == 'online')
              .map((peer) => peer['deviceId']?.toString())
              .whereType<String>());
      });
    } catch (_) {}
  }

  Map<String, dynamic> _normalizeOffer(Map<dynamic, dynamic> offer) {
    final normalized = Map<String, dynamic>.from(offer);
    if (DateTime.tryParse(normalized['expiresAt']?.toString() ?? '') == null) {
      final expiresInMs = (normalized['expiresInMs'] as num?)?.toInt();
      if (expiresInMs != null && expiresInMs > 0) {
        normalized['expiresAt'] = DateTime.now()
            .toUtc()
            .add(Duration(milliseconds: expiresInMs))
            .toIso8601String();
      }
    }
    return normalized;
  }

  String _sourceLabel(String? deviceId) {
    final peerId = _resolvePeerId(deviceId);
    if (peerId == null) return 'Loading device…';
    final name = _trustedPeerNames[peerId];
    return name == null || name.isEmpty ? 'Loading device…' : name;
  }

  String? _resolvePeerId(String? sourceDeviceId) {
    if (sourceDeviceId != null &&
        _trustedPeerNames.containsKey(sourceDeviceId)) {
      return sourceDeviceId;
    }
    if (_onlinePeerIds.length == 1) return _onlinePeerIds.single;
    if (_trustedPeerNames.length == 1) return _trustedPeerNames.keys.single;
    return null;
  }

  String _sourceDisplayLabel(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return 'Unknown device';
    final name = _trustedPeerNames[deviceId];
    return name == null || name.isEmpty ? deviceId : name;
  }

  IconData _sourcePlatformIcon(String? sourceDeviceId) {
    final platform =
        _trustedPeerPlatforms[_resolvePeerId(sourceDeviceId)]?.toLowerCase();
    return switch (platform) {
      'android' || 'ios' => Icons.smartphone,
      'windows' => Icons.desktop_windows,
      'macos' || 'mac' || 'osx' => Icons.laptop_mac,
      'linux' => Icons.computer,
      _ => Icons.devices,
    };
  }

  List<Map<String, dynamic>> _getSortedOffers(
      DesktopClipboardManager? manager) {
    final offers = manager != null && manager.activeOffers.isNotEmpty
        ? manager.activeOffers.values.toList(growable: false)
        : _daemonOffers;
    return List<Map<String, dynamic>>.from(offers)
        .where(
          (offer) =>
              offer['sourceDeviceId']?.toString() != _localDeviceId &&
              !_isExpired(offer),
        )
        .toList(growable: false)
      ..sort((a, b) {
        final expA = DateTime.tryParse(a['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final expB = DateTime.tryParse(b['expiresAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return expB.compareTo(expA);
      });
  }

  bool _isExpired(Map<String, dynamic> offer) {
    final expiresAt = DateTime.tryParse(offer['expiresAt']?.toString() ?? '');
    return expiresAt != null && !expiresAt.isAfter(DateTime.now());
  }

  void _removeExpiredOffers() {
    _daemonOffers.removeWhere(_isExpired);
  }

  String _remainingTime(Map<String, dynamic> offer) {
    final expiresAt = DateTime.tryParse(offer['expiresAt']?.toString() ?? '');
    if (expiresAt == null) return '--:--';
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return '00:00';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  String _contentTypeLabel(String mediaType) {
    if (mediaType.startsWith('text/')) return 'TEXT';
    if (mediaType.startsWith('image/')) return 'IMAGE';
    return 'FILE';
  }

  List<MapEntry<String?, int>> _computeSourceEntries(
      List<Map<String, dynamic>> offers) {
    final counts = <String?, int>{};
    for (final o in offers) {
      final sourceDeviceId = o['sourceDeviceId']?.toString();
      counts[sourceDeviceId] = (counts[sourceDeviceId] ?? 0) + 1;
    }
    return counts.entries.toList(growable: false);
  }

  List<MapEntry<String, int>> _computeTypeEntries(
      List<Map<String, dynamic>> offers) {
    final counts = <String, int>{};
    for (final o in offers) {
      final mediaType =
          o['contentType']?.toString() ?? 'application/octet-stream';
      final typeLabel = _contentTypeLabel(mediaType);
      counts[typeLabel] = (counts[typeLabel] ?? 0) + 1;
    }
    return counts.entries.toList(growable: false);
  }

  List<Map<String, dynamic>> _filterOffers(List<Map<String, dynamic>> offers) {
    return offers.where((o) {
      final sourceDeviceId = o['sourceDeviceId']?.toString();
      if (_preferredSourceDeviceId != null &&
          sourceDeviceId != _preferredSourceDeviceId) {
        return false;
      }
      if (_filteredSourceDeviceIds.isNotEmpty &&
          !_filteredSourceDeviceIds.contains(sourceDeviceId)) {
        return false;
      }
      final mediaType =
          o['contentType']?.toString() ?? 'application/octet-stream';
      final typeLabel = _contentTypeLabel(mediaType);
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
          const SizedBox(height: 12),
          if (visibleOffers.isEmpty)
            _buildEmptyState(theme, allOffers.isEmpty)
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleOffers.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
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
                if (_iosClipboardActions)
                  FilledButton.icon(
                    onPressed: _sendClipboard,
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Send Clipboard'),
                  ),
                _buildDeviceFilterMenu(theme, totalSources, sourceEntries),
                _buildTypeFilterMenu(theme, totalTypes, typeEntries),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment:
                  isMobile ? MainAxisAlignment.start : MainAxisAlignment.end,
              children: [
                _buildStatItem(theme, '$visibleCount', 'ITEMS'),
                const SizedBox(width: 20),
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
          Icon(
            Icons.content_paste_off_outlined,
            size: 36,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 10),
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
                    '${_sourceDisplayLabel(deviceId)} ($count)',
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
    final isText = mediaType.startsWith('text/');

    return Container(
      key: ValueKey('clipboard-offer-${offer['offerId']}'),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
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
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _sourcePlatformIcon(sourceDeviceId),
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _sourceLabel(sourceDeviceId),
                      style: theme.textTheme.bodyMedium?.copyWith(
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
                      _contentTypeLabel(mediaType),
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
              const SizedBox(height: 4),
              if (isMobile)
                Row(
                  children: [
                    Expanded(
                      child: _buildExpiryAndSize(theme, offer, sizeLabel),
                    ),
                    _buildActionButtons(theme, isText, offer),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildExpiryAndSize(theme, offer, sizeLabel),
                    _buildActionButtons(theme, isText, offer),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildExpiryAndSize(
    ThemeData theme,
    Map<String, dynamic> offer,
    String sizeLabel,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          _remainingTime(offer),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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
    final copyLabel = isText ? 'Copy' : 'Copy Image';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: () => _copyOffer(offer),
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: Text(copyLabel),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            visualDensity: VisualDensity.compact,
          ),
        ),
        if (!isText) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => _saveOffer(offer),
            icon: const Icon(Icons.download_outlined, size: 18),
            tooltip: 'Save',
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              minimumSize: const Size(0, 32),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _sendClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<JsonRpcRiftClient>();
    try {
      IOSClipboardContent? content;
      if (widget.readClipboardContentOverride != null) {
        content = await widget.readClipboardContentOverride!();
      } else if (widget.readClipboardTextOverride != null) {
        final text = await widget.readClipboardTextOverride!();
        if (text != null) {
          content = IOSClipboardContent(
            contentType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode(text)),
          );
        }
      } else if (Platform.isIOS) {
        content = await IOSClipboard.readContent();
      } else if (Platform.isAndroid) {
        content = await _readAndroidClipboardContent();
      } else {
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text != null) {
          content = IOSClipboardContent(
            contentType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode(text)),
          );
        }
      }

      if (content == null || content.bytes.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('The clipboard has no text or image to send.'),
          ),
        );
        return;
      }

      final sha256Hash = sha256.convert(content.bytes).toString();
      await client.notifyClipboardChange(
        contentType: content.contentType,
        byteSize: content.bytes.length,
        sha256: sha256Hash,
        contentBase64: base64Encode(content.bytes),
      );
      final isImage = content.contentType.startsWith('image/');
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              isImage
                  ? 'Clipboard image sent to trusted devices.'
                  : 'Clipboard sent to trusted devices.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error publishing clipboard: $e')),
        );
      }
    }
  }

  Future<IOSClipboardContent?> _readAndroidClipboardContent() async {
    final raw = await const MethodChannel('rift/android/clipboard')
        .invokeMethod<Object>('getClipboardContent');
    if (raw is! Map) return null;
    final contentType = raw['contentType'] as String?;
    final bytes = raw['bytes'];
    if (contentType == null || bytes is! Uint8List) return null;
    return IOSClipboardContent(contentType: contentType, bytes: bytes);
  }

  Future<void> _copyOffer(Map<String, dynamic> offer) async {
    final manager = context.read<DesktopClipboardManager?>();
    final offerId = offer['offerId']?.toString();
    if (offerId == null) return;

    if (manager != null) {
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
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    try {
      final content = await client.fetchClipboardContent(offerId);
      final rawType = content['contentType']?.toString() ?? 'text/plain';
      Uint8List? bytes = content['bytes'] as Uint8List?;
      if (bytes == null && content['contentBase64'] != null) {
        bytes = base64Decode(content['contentBase64'].toString());
      }

      if (bytes != null) {
        if (widget.writeClipboardContentOverride != null) {
          await widget.writeClipboardContentOverride!(
            IOSClipboardContent(contentType: rawType, bytes: bytes),
          );
        }
        if (widget.writeClipboardTextOverride != null) {
          final text = utf8.decode(bytes);
          await widget.writeClipboardTextOverride!(text);
        }
        if (widget.writeClipboardContentOverride == null &&
            widget.writeClipboardTextOverride == null) {
          if (Platform.isIOS) {
            await IOSClipboard.writeContent(
              IOSClipboardContent(contentType: rawType, bytes: bytes),
            );
          } else {
            final text = utf8.decode(bytes);
            await Clipboard.setData(ClipboardData(text: text));
          }
        }
        if (mounted) {
          RiftSnackbar.show(
            context: context,
            message: 'Copied to clipboard.',
            type: RiftSnackbarType.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        RiftSnackbar.show(
          context: context,
          message: 'Failed to copy clipboard content: $e',
          type: RiftSnackbarType.error,
        );
      }
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
      _preferredSourceDeviceId = null;
      if (_filteredSourceDeviceIds.contains(deviceId)) {
        _filteredSourceDeviceIds.remove(deviceId);
      } else {
        _filteredSourceDeviceIds.add(deviceId);
      }
    });
    widget.onTargetScopeCleared?.call();
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
