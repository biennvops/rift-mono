import 'package:flutter/material.dart';

import '../../src/ui/motion.dart';

enum DeviceHubMode {
  trusted,
  nearby,
}

class DeviceHubView extends StatelessWidget {
  const DeviceHubView({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.trustedScene,
    required this.nearbyScene,
    this.actions = const [],
    this.banner,
    this.modeSelectionEnabled = true,
  });

  final DeviceHubMode mode;
  final ValueChanged<DeviceHubMode> onModeChanged;
  final Widget trustedScene;
  final Widget nearbyScene;
  final List<Widget> actions;
  final Widget? banner;
  final bool modeSelectionEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = RiftMotion.durationOf(context, RiftMotion.normal);
    final scene = mode == DeviceHubMode.trusted ? trustedScene : nearbyScene;
    return Scaffold(
      key: const ValueKey('desktop-device-hub'),
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  Text(
                    'Devices Hub',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<DeviceHubMode>(
                        segments: const [
                          ButtonSegment(
                            value: DeviceHubMode.trusted,
                            label: Text(
                              'Trusted',
                              key: ValueKey('device-hub-mode-trusted'),
                            ),
                            icon: Icon(Icons.verified_user_outlined, size: 18),
                          ),
                          ButtonSegment(
                            value: DeviceHubMode.nearby,
                            label: Text(
                              'Nearby',
                              key: ValueKey('device-hub-mode-nearby'),
                            ),
                            icon: Icon(Icons.radar, size: 18),
                          ),
                        ],
                        selected: {mode},
                        showSelectedIcon: false,
                        onSelectionChanged: modeSelectionEnabled
                            ? (selection) {
                                if (selection.isNotEmpty) {
                                  onModeChanged(selection.first);
                                }
                              }
                            : null,
                      ),
                      ...actions,
                    ],
                  ),
                ],
              ),
              if (banner != null) ...[
                const SizedBox(height: 12),
                banner!,
              ],
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedSwitcher(
                      duration: duration,
                      switchInCurve: RiftMotion.enter,
                      switchOutCurve: RiftMotion.exit,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.99, end: 1).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: RiftMotion.enter,
                              ),
                            ),
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey('device-hub-scene-${mode.name}'),
                        child: scene,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
