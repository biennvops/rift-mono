import 'package:flutter/material.dart';

class ClipboardHistoryScreen extends StatefulWidget {
  const ClipboardHistoryScreen({super.key});

  @override
  State<ClipboardHistoryScreen> createState() => _ClipboardHistoryScreenState();
}

class _ClipboardHistoryScreenState extends State<ClipboardHistoryScreen> {
  String _activeFilter = 'Tất cả';

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
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: isActive ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
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

  Widget _buildTransactionItem({
    required ThemeData theme,
    required String type, // 'received', 'sent', 'error'
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
    IconData statusIcon;
    Color statusIconColor;

    if (type == 'received') {
      iconData = Icons.download;
      iconBgColor = theme.colorScheme.secondaryContainer;
      iconColor = theme.colorScheme.onSecondaryContainer;
      bgColor = theme.colorScheme.surfaceContainerLowest;
      borderColor = theme.colorScheme.outlineVariant;
      dotColor = theme.colorScheme.secondary;
      statusIcon = Icons.verified_user;
      statusIconColor = theme.colorScheme.outlineVariant;
    } else if (type == 'sent') {
      iconData = Icons.upload;
      iconBgColor = theme.colorScheme.surfaceContainerHighest;
      iconColor = theme.colorScheme.onSurfaceVariant;
      bgColor = theme.colorScheme.surfaceContainerLowest;
      borderColor = theme.colorScheme.outlineVariant;
      dotColor = theme.colorScheme.secondary;
      statusIcon = Icons.verified_user;
      statusIconColor = theme.colorScheme.outlineVariant;
    } else {
      // error
      iconData = Icons.error;
      iconBgColor = theme.colorScheme.surfaceContainerLowest;
      iconColor = theme.colorScheme.error;
      bgColor = theme.colorScheme.errorContainer;
      borderColor = theme.colorScheme.errorContainer; // Match background to hide border
      dotColor = theme.colorScheme.error;
      statusIcon = Icons.gpp_bad;
      statusIconColor = theme.colorScheme.error;
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
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: type == 'error' ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: type == 'error' ? theme.colorScheme.onErrorContainer.withValues(alpha: 0.8) : theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.5,
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
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: type == 'error' ? theme.colorScheme.onErrorContainer.withValues(alpha: 0.8) : theme.colorScheme.onSurfaceVariant,
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

    // Filter items based on active filter
    final allItems = [
      {'type': 'received', 'device': 'Alpha-Workstation', 'hash': 'a7b9...3f21', 'size': '42 KB', 'time': '10:42 AM'},
      {'type': 'sent', 'device': 'Mobile-Node-1', 'hash': '9c2f...e11a', 'size': '1.2 MB', 'time': '09:15 AM'},
      {'type': 'error', 'device': 'Unknown-Device', 'hash': '----', 'size': '0 KB', 'time': 'Yesterday'},
      {'type': 'received', 'device': 'Beta-Server', 'hash': 'd4e5...88bb', 'size': '15 KB', 'time': 'Yesterday'},
    ];

    List<Map<String, String>> filteredItems = allItems;
    if (_activeFilter == 'Đã gửi') {
      filteredItems = allItems.where((i) => i['type'] == 'sent').toList();
    } else if (_activeFilter == 'Đã nhận') {
      filteredItems = allItems.where((i) => i['type'] == 'received').toList();
    } else if (_activeFilter == 'Lỗi') {
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
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Global transaction log across all trusted connections.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip('Tất cả', theme),
                    _buildFilterChip('Đã gửi', theme),
                    _buildFilterChip('Đã nhận', theme),
                    _buildFilterChip('Lỗi', theme),
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
