import 'package:flutter/material.dart';

@immutable
class PairingIdentityPresentation {
  const PairingIdentityPresentation({
    required this.label,
    required this.displayName,
    required this.deviceId,
    required this.platform,
    required this.fingerprint,
  });

  final String label;
  final String displayName;
  final String? deviceId;
  final String? platform;
  final String? fingerprint;
}

class PairingVerificationView extends StatelessWidget {
  const PairingVerificationView({
    super.key,
    required this.localIdentity,
    required this.peerIdentity,
    required this.status,
    required this.error,
    required this.remainingSeconds,
    required this.hasActivePairing,
    required this.isRecipient,
    required this.busy,
    required this.expired,
    required this.approveEnabled,
    required this.approveDelayComplete,
    required this.canReject,
    required this.onApprove,
    required this.onReject,
    required this.onClose,
  });

  final PairingIdentityPresentation localIdentity;
  final PairingIdentityPresentation peerIdentity;
  final String status;
  final String? error;
  final int? remainingSeconds;
  final bool hasActivePairing;
  final bool isRecipient;
  final bool busy;
  final bool expired;
  final bool approveEnabled;
  final bool approveDelayComplete;
  final bool canReject;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isMobile = MediaQuery.sizeOf(context).width < 680;
    return Material(
      key: const ValueKey('pairing-verification-shell'),
      elevation: 12,
      shadowColor: colors.primary.withValues(alpha: 0.16),
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 820,
          maxHeight: MediaQuery.sizeOf(context).height * 0.94,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isMobile ? 20 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pair devices',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (expired)
                    Text(
                      'Expired',
                      key: const ValueKey('pairing-expired'),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else if (remainingSeconds != null)
                    Text(
                      '${remainingSeconds}s',
                      key: const ValueKey('pairing-countdown'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Verify both identities before trusting.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (isMobile)
                Column(
                  children: [
                    PairingIdentityCard(
                      key: const ValueKey('pairing-local-card'),
                      identity: localIdentity,
                    ),
                    const SizedBox(height: 12),
                    PairingIdentityCard(
                      key: const ValueKey('pairing-peer-card'),
                      identity: peerIdentity,
                    ),
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: PairingIdentityCard(
                        key: const ValueKey('pairing-local-card'),
                        identity: localIdentity,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PairingIdentityCard(
                        key: const ValueKey('pairing-peer-card'),
                        identity: peerIdentity,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 14),
              Text(
                'Only continue if the identities shown on both devices correspond.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                key: const ValueKey('pairing-state'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: error == null
                      ? colors.surfaceContainerLow
                      : colors.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    if (busy) ...[
                      const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 9),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onErrorContainer,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildFooter(context, isMobile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, bool isMobile) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (!hasActivePairing) {
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          key: const ValueKey('pairing-close'),
          onPressed: onClose,
          child: const Text('Close'),
        ),
      );
    }

    final rejectButton = OutlinedButton(
      key: ValueKey(isRecipient ? 'pairing-reject' : 'pairing-cancel'),
      onPressed: canReject ? onReject : null,
      child: Text(isRecipient ? 'Reject' : 'Cancel'),
    );
    if (!isRecipient) {
      final waiting = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              'Waiting for ${peerIdentity.displayName} to approve…',
              key: const ValueKey('pairing-waiting-for-peer'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
      if (isMobile) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [waiting, const SizedBox(height: 12), rejectButton],
        );
      }
      return Row(
        children: [Expanded(child: waiting), rejectButton],
      );
    }

    final approveButton = FilledButton.icon(
      key: const ValueKey('pairing-approve'),
      onPressed: approveEnabled ? onApprove : null,
      icon: busy
          ? const SizedBox.square(
              dimension: 17,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.verified_user_outlined, size: 18),
      label: const Text('Trust & Pair'),
    );
    final delayMessage = !approveDelayComplete && !expired
        ? Text(
            'Verify fingerprints before continuing…',
            key: const ValueKey('pairing-approval-delay'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          )
        : null;

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (delayMessage != null) ...[
            delayMessage,
            const SizedBox(height: 10),
          ],
          approveButton,
          const SizedBox(height: 10),
          rejectButton,
        ],
      );
    }
    return Row(
      children: [
        if (delayMessage != null)
          Expanded(child: delayMessage)
        else
          const Spacer(),
        rejectButton,
        const SizedBox(width: 10),
        approveButton,
      ],
    );
  }
}

class PairingIdentityCard extends StatelessWidget {
  const PairingIdentityCard({super.key, required this.identity});

  final PairingIdentityPresentation identity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final normalizedPlatform = identity.platform?.trim().toLowerCase();
    final platformLabel = const {
      'android',
      'ios',
      'windows',
      'macos',
      'linux',
    }.contains(normalizedPlatform)
        ? normalizedPlatform!.toUpperCase()
        : null;
    final side = identity.label == 'This Device' ? 'local' : 'peer';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  identity.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (platformLabel != null) ...[
                const SizedBox(width: 8),
                Icon(
                  _platformIcon(normalizedPlatform!),
                  size: 15,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  platformLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            identity.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            identity.deviceId ?? 'Loading identity…',
            key: ValueKey('pairing-$side-device-id'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFamily: 'JetBrains Mono',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Fingerprint',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            _formatFingerprint(identity.fingerprint),
            key: ValueKey('pairing-$side-fingerprint'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: identity.fingerprint == null
                  ? colors.onSurfaceVariant
                  : colors.onSurface,
              fontFamily: 'JetBrains Mono',
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatFingerprint(String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) {
      return 'Loading fingerprint…';
    }
    final clean =
        fingerprint.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return fingerprint;
    final chunks = <String>[];
    for (var index = 0; index < clean.length; index += 4) {
      chunks.add(
        clean.substring(
          index,
          (index + 4).clamp(0, clean.length).toInt(),
        ),
      );
    }
    return chunks.join('-');
  }

  static IconData _platformIcon(String platform) => switch (platform) {
        'android' || 'ios' => Icons.smartphone,
        'windows' => Icons.desktop_windows,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.computer,
        _ => Icons.devices,
      };
}
