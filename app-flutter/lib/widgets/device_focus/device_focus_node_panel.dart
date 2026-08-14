import 'package:flutter/material.dart';

import 'device_focus_layout.dart';

class DeviceFocusPanelRow {
  const DeviceFocusPanelRow({
    required this.label,
    required this.value,
    this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;
}

class DeviceFocusNodePanel extends StatelessWidget {
  const DeviceFocusNodePanel({
    super.key,
    required this.kind,
    required this.title,
    required this.icon,
    required this.maxHeight,
    required this.onClose,
    this.rows = const [],
    this.body,
    this.footer,
    this.accentColor,
    this.elevation = 10,
    this.borderRadius = 14,
    this.contentOpacity = 1,
  });

  final DeviceFocusNodeKind kind;
  final String title;
  final IconData icon;
  final List<DeviceFocusPanelRow> rows;
  final double maxHeight;
  final VoidCallback onClose;
  final Widget? body;
  final Widget? footer;
  final Color? accentColor;
  final double elevation;
  final double borderRadius;
  final double contentOpacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentColor ?? colors.primary;
    return SizedBox(
      height: maxHeight,
      child: Material(
        elevation: elevation,
        shadowColor: accent.withValues(alpha: 0.18),
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.025),
          colors.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Opacity(
          opacity: contentOpacity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, size: 20, color: accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('device-focus-panel-close'),
                      tooltip: 'Close details',
                      onPressed: onClose,
                      icon: const Icon(Icons.close, size: 20),
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (body != null)
                            body!
                          else ...[
                            for (var index = 0;
                                index < rows.length;
                                index++) ...[
                              _PanelRow(row: rows[index]),
                              if (index != rows.length - 1)
                                Divider(
                                  color: colors.outlineVariant,
                                  height: 17,
                                ),
                            ],
                            if (footer != null) ...[
                              const SizedBox(height: 16),
                              footer!,
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.row});

  final DeviceFocusPanelRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              row.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            row.value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurface,
              fontFamily: row.onCopy == null ? null : 'JetBrains Mono',
            ),
          ),
        ),
        if (row.onCopy != null)
          IconButton(
            tooltip: 'Copy ${row.label}',
            visualDensity: VisualDensity.compact,
            onPressed: row.onCopy,
            icon: const Icon(Icons.copy, size: 17),
            color: colors.primary,
          ),
      ],
    );
  }
}
