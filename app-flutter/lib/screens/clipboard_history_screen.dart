import 'package:flutter/material.dart';

const _kSuccessColor = Color(0xFF047857);
const _kSuccessBgColor = Color(0x14047857);
const _kErrorColor = Color(0xFFBA1A1A);
const _kErrorBgColor = Color(0x14BA1A1A);

class ClipboardHistoryScreen extends StatefulWidget {
  const ClipboardHistoryScreen({super.key});

  @override
  State<ClipboardHistoryScreen> createState() => _ClipboardHistoryScreenState();
}

class _ClipboardHistoryScreenState extends State<ClipboardHistoryScreen> {
  String _activeFilter = 'All';

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
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? theme.colorScheme.primaryContainer : Colors.white,
            border: Border.all(
              color: isActive
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              color: isActive
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionItem({
    required ThemeData theme,
    required String type,
    required String deviceName,
    required String hash,
    required String size,
    required String time,
  }) {
    IconData iconData;
    Color iconBgColor;
    Color iconColor;
    Color bgColor;
    Color borderColor;
    Color dotColor;
    Color nameColor;
    Color metaColor;
    IconData statusIcon;
    Color statusIconColor;

    if (type == 'received') {
      iconData = Icons.download;
      iconBgColor = _kSuccessBgColor;
      iconColor = _kSuccessColor;
      bgColor = Colors.white;
      borderColor = theme.colorScheme.outlineVariant;
      dotColor = _kSuccessColor;
      nameColor = theme.colorScheme.onSurface;
      metaColor = theme.colorScheme.onSurfaceVariant;
      statusIcon = Icons.verified_user;
      statusIconColor = theme.colorScheme.outline;
    } else if (type == 'sent') {
      iconData = Icons.upload;
      iconBgColor = theme.colorScheme.surfaceContainerLow;
      iconColor = theme.colorScheme.onSurfaceVariant;
      bgColor = Colors.white;
      borderColor = theme.colorScheme.outlineVariant;
      dotColor = theme.colorScheme.primaryContainer;
      nameColor = theme.colorScheme.onSurface;
      metaColor = theme.colorScheme.onSurfaceVariant;
      statusIcon = Icons.verified_user;
      statusIconColor = theme.colorScheme.outline;
    } else {
      iconData = Icons.error;
      iconBgColor = _kErrorBgColor;
      iconColor = _kErrorColor;
      bgColor = theme.colorScheme.errorContainer;
      borderColor = theme.colorScheme.errorContainer;
      dotColor = _kErrorColor;
      nameColor = theme.colorScheme.onErrorContainer;
      metaColor = theme.colorScheme.onErrorContainer.withValues(alpha: 0.8);
      statusIcon = Icons.gpp_bad;
      statusIconColor = _kErrorColor;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconBgColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(iconData, color: iconColor, size: 20),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        deviceName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 24 / 16,
                          color: nameColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Hash: $hash • $size${type == 'error' ? ' • Blocked' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 16 / 12,
                      color: metaColor,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                time,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 20 / 14,
                  color: metaColor,
                ),
              ),
              const SizedBox(height: 8),
              Icon(statusIcon, color: statusIconColor, size: 16),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final allItems = [
      {
        'type': 'received',
        'device': 'Alpha-Workstation',
        'hash': 'a7b9...3f21',
        'size': '42 KB',
        'time': '10:42 AM'
      },
      {
        'type': 'sent',
        'device': 'Mobile-Node-1',
        'hash': '9c2f...e11a',
        'size': '1.2 MB',
        'time': '09:15 AM'
      },
      {
        'type': 'error',
        'device': 'Unknown-Device',
        'hash': '----',
        'size': '0 KB',
        'time': 'Yesterday'
      },
      {
        'type': 'received',
        'device': 'Beta-Server',
        'hash': 'd4e5...88bb',
        'size': '15 KB',
        'time': 'Yesterday'
      },
    ];

    List<Map<String, String>> filteredItems = allItems;
    if (_activeFilter == 'Sent') {
      filteredItems = allItems.where((i) => i['type'] == 'sent').toList();
    } else if (_activeFilter == 'Received') {
      filteredItems = allItems.where((i) => i['type'] == 'received').toList();
    } else if (_activeFilter == 'Errors') {
      filteredItems = allItems.where((i) => i['type'] == 'error').toList();
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              Text(
                'Clipboard History',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.01,
                  height: 32 / 24,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Global transaction log across all trusted connections.',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  height: 24 / 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip('All', theme),
                    _buildFilterChip('Sent', theme),
                    _buildFilterChip('Received', theme),
                    _buildFilterChip('Errors', theme),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: filteredItems.length,
                  itemBuilder: (context, index) {
                    final item = filteredItems[index];
                    return _buildTransactionItem(
                      theme: theme,
                      type: item['type']!,
                      deviceName: item['device']!,
                      hash: item['hash']!,
                      size: item['size']!,
                      time: item['time']!,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
