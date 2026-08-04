import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../src/platform/android_shell.dart';
import '../src/platform/macos_notifications.dart';
import '../src/platform/notification_route.dart';
import '../src/platform/windows_shell.dart';
import 'dart:async';

class PairingScreen extends StatefulWidget {
  final String? initialDeviceId;
  final String? initialEndpointAddress;
  final int? initialEndpointPort;
  final String? initialDisplayName;
  final String? initialPeerFingerprint;
  final int? initialExpiresInMs;
  final bool initialCanApproveLocally;
  final String? initialStatus;
  final bool autoStart;
  final VoidCallback? onClose;

  const PairingScreen({
    super.key,
    this.initialDeviceId,
    this.initialEndpointAddress,
    this.initialEndpointPort,
    this.initialDisplayName,
    this.initialPeerFingerprint,
    this.initialExpiresInMs,
    this.initialCanApproveLocally = false,
    this.initialStatus,
    this.autoStart = false,
    this.onClose,
  });

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  StreamSubscription<Map<String, dynamic>>? _requestSub;
  StreamSubscription<Map<String, dynamic>>? _completeSub;
  StreamSubscription<Map<String, dynamic>>? _trustSub;
  Timer? _countdownTimer;
  Timer? _approveDelayTimer;

  String? _deviceId;
  String? _displayName;
  String? _localFingerprint;
  String? _peerFingerprint;
  int? _expiresInMs;
  String _status = 'No active pairing yet';
  String? _error;
  bool _busy = false;
  int? _remainingSeconds;
  bool _hasActivePairingFlow = false;
  bool _canApproveLocally = false;
  bool _canApproveDelay = false;
  bool _isRecipientFlow = false;
  bool _isClosingAfterCompletion = false;
  Future<void>? _localFingerprintLoad;

  void _startApproveDelay() {
    setState(() {
      _canApproveDelay = false;
    });
    _approveDelayTimer?.cancel();
    _approveDelayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _hasActivePairingFlow && !_isClosingAfterCompletion) {
        setState(() {
          _canApproveDelay = true;
        });
      }
    });
  }

  Future<void> _ensureLocalFingerprint() {
    if (_localFingerprint != null && _localFingerprint!.isNotEmpty) {
      return Future.value();
    }
    final inFlight = _localFingerprintLoad;
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      try {
        final client = context.read<JsonRpcRiftClient>();
        final result = await client.getDeviceInfo();
        if (!mounted || result is! Map) {
          return;
        }
        final fingerprint = result['fingerprint']?.toString();
        if (fingerprint == null || fingerprint.isEmpty) {
          return;
        }
        setState(() {
          _localFingerprint ??= fingerprint;
        });
      } catch (_) {
      } finally {
        if (mounted) {
          _localFingerprintLoad = null;
        }
      }
    }();

    _localFingerprintLoad = future;
    return future;
  }

  @override
  void initState() {
    super.initState();
    _deviceId = widget.initialDeviceId;
    _displayName = widget.initialDisplayName;
    _peerFingerprint = widget.initialPeerFingerprint;
    _expiresInMs = widget.initialExpiresInMs;
    _status = widget.initialStatus ?? _status;
    _hasActivePairingFlow = widget.initialPeerFingerprint != null;
    _canApproveLocally = widget.initialCanApproveLocally;
    _isRecipientFlow = widget.initialCanApproveLocally;
    if (_hasActivePairingFlow) {
      _startApproveDelay();
    }
    _startCountdown(_expiresInMs);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClient();
      unawaited(_ensureLocalFingerprint());
      if (widget.autoStart && widget.initialEndpointAddress != null) {
        _startPairingByEndpoint(
          widget.initialEndpointAddress!,
          widget.initialEndpointPort ?? 11112,
        );
      } else if (widget.autoStart && widget.initialDeviceId != null) {
        _startPairing(widget.initialDeviceId!);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _approveDelayTimer?.cancel();
    _requestSub?.cancel();
    _completeSub?.cancel();
    _trustSub?.cancel();
    super.dispose();
  }

  void _bindClient() {
    final client = context.read<JsonRpcRiftClient>();
    _requestSub = client.onPairingRequest.listen((event) {
      if (!mounted) return;
      setState(() {
        _deviceId = event['deviceId']?.toString();
        _displayName = event['displayName']?.toString() ?? _deviceId;
        _peerFingerprint = event['fingerprint']?.toString();
        _expiresInMs = (event['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Incoming pairing request';
        _error = null;
        _busy = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = true;
        _isRecipientFlow = true;
      });
      unawaited(_ensureLocalFingerprint());
      _startApproveDelay();
    });
    _completeSub = client.onPairingComplete.listen((event) async {
      if (!mounted || event['deviceId']?.toString() != _deviceId) return;
      _peerFingerprint ??= event['fingerprint']?.toString();
      await _handlePairingCompleted();
    });
    _trustSub = client.onTrustChanged.listen((event) async {
      if (!mounted || event['deviceId']?.toString() != _deviceId) return;
      final newState = event['newState']?.toString();
      if (newState == 'trusted' && !_isClosingAfterCompletion) {
        await _handlePairingCompleted();
      } else if (newState == 'discovered' && !_isClosingAfterCompletion) {
        final shouldAutoClose = !_isRecipientFlow;
        setState(() {
          _status = 'Pairing closed';
          _busy = false;
          _hasActivePairingFlow = false;
          _peerFingerprint = null;
          _localFingerprint = null;
          _expiresInMs = null;
          _canApproveLocally = false;
        });
        _countdownTimer?.cancel();
        _remainingSeconds = null;
        if (shouldAutoClose && mounted) {
          if (widget.onClose != null) {
            widget.onClose!();
          } else {
            Navigator.of(context).maybePop();
          }
        }
      }
    });
  }

  Future<void> _handlePairingCompleted() async {
    if (!mounted || _isClosingAfterCompletion) return;
    _isClosingAfterCompletion = true;
    if (_isRecipientFlow) {
      await _showRecipientPairingSuccessNotice();
      if (!mounted) return;
    }
    if (!mounted) return;
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _showRecipientPairingSuccessNotice() async {
    final label = _displayName ?? _deviceId ?? 'device';
    final message = 'Paired successfully with $label';
    if (AndroidShell.isSupported) {
      await AndroidShell.showToast(message);
      return;
    }
    if (WindowsShell.isSupported) {
      await WindowsShell.showNotification(
        title: 'Pairing completed',
        body: message,
        route: NotificationRoute.devices,
      );
      return;
    }
    await MacOSNotifications.show(
      title: 'Pairing completed',
      body: message,
      route: NotificationRoute.devices,
    );
  }

  void _startCountdown(int? expiresInMs) {
    _countdownTimer?.cancel();
    if (expiresInMs == null || expiresInMs <= 0) {
      _remainingSeconds = null;
      return;
    }
    _remainingSeconds = (expiresInMs / 1000).ceil();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = (_remainingSeconds ?? 1) - 1;
      if (next <= 0) {
        setState(() {
          _remainingSeconds = 0;
          _busy = false;
          if (!_isClosingAfterCompletion) {
            _status = 'Pairing request expired';
          }
        });
        timer.cancel();
        return;
      }
      setState(() {
        _remainingSeconds = next;
      });
    });
  }

  Future<void> _startPairing(String deviceId) async {
    if (_busy && _deviceId == deviceId) return;
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _deviceId = deviceId;
      _status = 'Starting pairing';
      _error = null;
      _hasActivePairingFlow = false;
      _canApproveLocally = false;
    });
    try {
      final result = await client.startPairing(deviceId) as Map;
      final resolvedDeviceId = result['deviceId']?.toString() ?? deviceId;
      final resolvedDisplayName =
          result['displayName']?.toString() ?? _displayName ?? resolvedDeviceId;
      if (!mounted) return;
      setState(() {
        _deviceId = resolvedDeviceId;
        _displayName = resolvedDisplayName;
        _localFingerprint = result['fingerprint']?.toString();
        _peerFingerprint = result['peerFingerprint']?.toString();
        _expiresInMs = (result['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Confirm fingerprint to continue';
        _busy = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = false;
        _isRecipientFlow = false;
      });
      _startApproveDelay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _peerFingerprint = null;
        _localFingerprint = null;
        _expiresInMs = null;
        _remainingSeconds = null;
        _error = _formatUserFacingError(e);
        _status = 'Unable to start pairing';
        _busy = false;
        _hasActivePairingFlow = false;
        _canApproveLocally = false;
      });
    }
  }

  Future<void> _startPairingByEndpoint(String address, int port) async {
    if (_busy) return;
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _status = 'Connecting to $address:$port';
      _error = null;
      _hasActivePairingFlow = false;
      _canApproveLocally = false;
    });
    try {
      final result = await client.startPairingByEndpoint(address, port) as Map;
      if (!mounted) return;
      final resolvedDeviceId = result['deviceId']?.toString();
      final resolvedDisplayName = result['displayName']?.toString() ??
          resolvedDeviceId ??
          _displayName ??
          '$address:$port';
      setState(() {
        _deviceId = resolvedDeviceId;
        _displayName = resolvedDisplayName;
        _localFingerprint = result['fingerprint']?.toString();
        _peerFingerprint = result['peerFingerprint']?.toString();
        _expiresInMs = (result['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Confirm fingerprint to continue';
        _busy = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = false;
        _isRecipientFlow = false;
      });
      _startApproveDelay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _peerFingerprint = null;
        _localFingerprint = null;
        _expiresInMs = null;
        _remainingSeconds = null;
        _error = _formatUserFacingError(e);
        _status = 'Unable to start pairing';
        _busy = false;
        _hasActivePairingFlow = false;
        _canApproveLocally = false;
      });
    }
  }

  Future<void> _approvePairing() async {
    final deviceId = _deviceId;
    final peerFingerprint = _peerFingerprint;
    if (deviceId == null || peerFingerprint == null) return;
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Approving pairing';
    });
    try {
      await client.approvePairing(deviceId, peerFingerprint);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Approval sent. Waiting for completion';
        _canApproveLocally = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _formatUserFacingError(e);
        _canApproveLocally = false;
      });
    }
  }

  Future<void> _rejectPairing() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await client.rejectPairing(deviceId);
      if (!mounted) return;
      if (!_isRecipientFlow) {
        if (widget.onClose != null) {
          widget.onClose!();
        } else {
          Navigator.of(context).maybePop();
        }
        return;
      }
      setState(() {
        _busy = false;
        _status = 'Pairing rejected';
        _error = null;
        _hasActivePairingFlow = false;
        _peerFingerprint = null;
        _localFingerprint = null;
        _expiresInMs = null;
        _canApproveLocally = false;
        _countdownTimer?.cancel();
        _remainingSeconds = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _formatUserFacingError(e);
      });
    }
  }

  String _formatUserFacingError(Object error) {
    final formatted = JsonRpcRiftClient.formatDisplayError(error);
    if (formatted == 'This device is no longer available.') {
      return 'This device is no longer available for pairing.';
    }
    return formatted;
  }

  Widget _buildFingerprintText(
    ThemeData theme,
    String? fp, {
    TextStyle? textStyle,
    Color? dividerColor,
    double letterSpacing = 4,
  }) {
    final defaultStyle = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: letterSpacing,
      height: 32 / 24,
      color: theme.colorScheme.primaryContainer,
    );
    final effectiveStyle = textStyle ?? defaultStyle;

    if (fp == null) {
      return Text('WAITING...', style: effectiveStyle);
    }

    final clean = fp.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) {
      return Text(fp, style: effectiveStyle);
    }

    final limit = clean.length > 16 ? 16 : clean.length;
    final truncated = clean.substring(0, limit);

    final chunks = <String>[];
    for (int i = 0; i < truncated.length; i += 4) {
      chunks.add(truncated.substring(
          i, (i + 4) > truncated.length ? truncated.length : i + 4));
    }

    final widgets = <Widget>[];
    for (int i = 0; i < chunks.length; i++) {
      widgets.add(Text(chunks[i], style: effectiveStyle));
      if (i < chunks.length - 1) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '|',
            style: effectiveStyle.copyWith(
              fontWeight: FontWeight.w400,
              color: dividerColor ?? theme.colorScheme.outlineVariant,
            ),
          ),
        ));
      }
    }

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: widgets,
      ),
    );
  }

  Widget _buildRecipientFlow(
      BuildContext context,
      ThemeData theme,
      bool hasExpired,
      bool canApprove,
      bool canReject,
      bool approveEnabled,
      bool isMobile,
      String deviceName) {
    final route = ModalRoute.of(context);
    final isDialogOrEmbedded = route is PopupRoute || widget.onClose != null;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          if (!isDialogOrEmbedded)
            Positioned.fill(
              child: Container(color: theme.colorScheme.surface),
            ),
          Center(
            child: Container(
              width: 512,
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.95),
              margin: EdgeInsets.all(isMobile ? 16 : 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primaryContainer
                        .withValues(alpha: 0.1),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      height: 4, color: theme.colorScheme.primaryContainer),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(isMobile ? 24 : 32),
                      child: Column(
                        children: [
                          const PulseRingIcon(icon: Icons.phonelink_ring),
                          const SizedBox(height: 16),
                          Text('Pairing Request',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.01,
                                height: 32 / 24,
                                color: theme.colorScheme.onSurface,
                              )),
                          const SizedBox(height: 8),
                          Text(
                            'A new device is attempting to establish a secure link with your account.',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w400,
                              height: 24 / 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          Text('Compare fingerprints',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.05,
                                height: 16 / 14,
                                color: theme.colorScheme.onSurface,
                              ),
                              textAlign: TextAlign.center),
                          if (hasExpired)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text('Expired',
                                  style: TextStyle(
                                      color: theme.colorScheme.error,
                                      fontWeight: FontWeight.w600)),
                            )
                          else if (_remainingSeconds != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text('Expires in ${_remainingSeconds!}s',
                                  style: TextStyle(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                  color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color:
                                        theme.colorScheme.surfaceContainerLow,
                                    border: Border.all(
                                        color:
                                            theme.colorScheme.outlineVariant),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(Icons.desktop_windows,
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(deviceName,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            height: 24 / 16,
                                            color: theme.colorScheme.onSurface,
                                          )),
                                      Text('Secure Sync v0.1',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            height: 20 / 14,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          )),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                  color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: [
                                Text('VERIFY SECURITY FINGERPRINT',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.05,
                                      height: 16 / 14,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    )),
                                const SizedBox(height: 16),
                                _buildFingerprintText(
                                  theme,
                                  _peerFingerprint ?? _localFingerprint,
                                  textStyle: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 3,
                                    height: 32 / 24,
                                    color: theme.colorScheme.primaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Ensure this code matches exactly with the code displayed on the requesting device.',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    height: 20 / 14,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.all(isMobile ? 24 : 32),
                    decoration: BoxDecoration(
                      border: Border(
                          top: BorderSide(
                              color: theme.colorScheme.outlineVariant)),
                    ),
                    child: Builder(builder: (context) {
                      final rejectBtn = OutlinedButton.icon(
                        onPressed: canReject ? _rejectPairing : null,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Reject',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          side: BorderSide(color: theme.colorScheme.error),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4)),
                        ),
                      );
                      final approveBtn = _canApproveLocally
                          ? FilledButton.icon(
                              onPressed:
                                  approveEnabled ? _approvePairing : null,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.check_circle, size: 18),
                              label: const Text('Approve',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                foregroundColor: theme.colorScheme.onPrimary,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                            )
                          : Container(
                              height: 40,
                              alignment: Alignment.center,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('Waiting for peer...',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    height: 20 / 14,
                                    color: theme.colorScheme.outline,
                                  )),
                            );
                      if (isMobile) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            approveBtn,
                            const SizedBox(height: 12),
                            if (canReject) rejectBtn,
                          ],
                        );
                      }
                      return Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 16,
                        runSpacing: 12,
                        children: [
                          if (canReject) rejectBtn,
                          approveBtn,
                        ],
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final hasExpired = (_remainingSeconds != null &&
        _remainingSeconds == 0 &&
        !_isClosingAfterCompletion);
    final canApprove = !_busy &&
        !_isClosingAfterCompletion &&
        !hasExpired &&
        _hasActivePairingFlow &&
        _canApproveLocally &&
        _deviceId != null &&
        _peerFingerprint != null;
    final canReject = !_busy &&
        !_isClosingAfterCompletion &&
        _deviceId != null &&
        _hasActivePairingFlow;
    final approveEnabled = canApprove && _canApproveDelay;
    final deviceName = _displayName ?? _deviceId ?? 'Unknown';
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (_isRecipientFlow && _hasActivePairingFlow) {
      return _buildRecipientFlow(context, theme, hasExpired, canApprove,
          canReject, approveEnabled, isMobile, deviceName);
    }

    final title = 'Verify Connection';
    final subtitle = 'Pairing request sent to ';

    final route = ModalRoute.of(context);
    final isDialogOrEmbedded = route is PopupRoute || widget.onClose != null;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          if (!isDialogOrEmbedded)
            Positioned.fill(
              child: Container(color: theme.colorScheme.surface),
            ),
          Center(
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                maxWidth: 448,
                maxHeight: MediaQuery.of(context).size.height * 0.95,
              ),
              margin: EdgeInsets.all(isMobile ? 16 : 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primaryContainer
                        .withValues(alpha: 0.1),
                    blurRadius: 40,
                    offset: const Offset(0, 24),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(isMobile ? 24 : 32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                          bottom: BorderSide(
                              color: theme.colorScheme.outlineVariant)),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.fingerprint,
                              size: 32,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.01,
                            height: 32 / 24,
                            color: theme.colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w400,
                              height: 28 / 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            children: [
                              TextSpan(text: subtitle),
                              TextSpan(
                                text: deviceName,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const TextSpan(text: '.'),
                            ],
                          ),
                        ),
                        if (hasExpired)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('Expired',
                                style: TextStyle(
                                    color: theme.colorScheme.error,
                                    fontWeight: FontWeight.w600)),
                          )
                        else if (_remainingSeconds != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('Expires in ${_remainingSeconds!}s',
                                style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(isMobile ? 24 : 32),
                      child: !_hasActivePairingFlow
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_busy) const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(_status,
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w400,
                                      height: 28 / 18,
                                      color: theme.colorScheme.onSurface,
                                    )),
                                if (_error != null) ...[
                                  const SizedBox(height: 12),
                                  Text(_error!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: theme.colorScheme.error)),
                                ]
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  'Compare fingerprints',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.05,
                                    height: 16 / 14,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Compare the security fingerprint below with the one displayed on the destination device. They must match exactly.',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w400,
                                    height: 24 / 16,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  "This device's fingerprint",
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    height: 20 / 14,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ShimmerPulseContainer(
                                  child: _buildFingerprintText(theme,
                                      _peerFingerprint ?? _localFingerprint),
                                ),
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color:
                                            theme.colorScheme.outlineVariant),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.info,
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                          size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'If the codes do not match, reject this request immediately. Your connection may be intercepted.',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            height: 20 / 14,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  if (_hasActivePairingFlow)
                    Container(
                      padding: EdgeInsets.all(isMobile ? 24 : 32),
                      decoration: BoxDecoration(
                        border: Border(
                            top: BorderSide(
                                color: theme.colorScheme.outlineVariant)),
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(12)),
                      ),
                      child: Builder(builder: (context) {
                        final rejectBtn = OutlinedButton(
                          onPressed: canReject ? _rejectPairing : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.primaryContainer,
                            side: BorderSide(
                                color: theme.colorScheme.primaryContainer),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4)),
                          ),
                          child: const Text('Reject',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        );
                        final approveBtn = _canApproveLocally
                            ? FilledButton.icon(
                                onPressed:
                                    approveEnabled ? _approvePairing : null,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white))
                                    : const Icon(Icons.check_circle, size: 20),
                                label: const Text('Approve',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      theme.colorScheme.primaryContainer,
                                  foregroundColor: theme.colorScheme.onPrimary,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4)),
                                ),
                              )
                            : Container(
                                height: 40,
                                alignment: Alignment.center,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Text('Waiting for peer...',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      height: 20 / 14,
                                      color: theme.colorScheme.outline,
                                    )),
                              );
                        if (isMobile) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              approveBtn,
                              const SizedBox(height: 12),
                              if (_isRecipientFlow || canReject) rejectBtn,
                            ],
                          );
                        }
                        return Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 16,
                          runSpacing: 12,
                          children: [
                            if (_isRecipientFlow || canReject) rejectBtn,
                            approveBtn,
                          ],
                        );
                      }),
                    )
                  else
                    Container(
                      padding: EdgeInsets.all(isMobile ? 24 : 32),
                      decoration: BoxDecoration(
                        border: Border(
                            top: BorderSide(
                                color: theme.colorScheme.outlineVariant)),
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(12)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              foregroundColor: theme.colorScheme.onPrimary,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4)),
                            ),
                            child: const Text('Close',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ShimmerPulseContainer extends StatefulWidget {
  final Widget child;
  const ShimmerPulseContainer({super.key, required this.child});
  @override
  State<ShimmerPulseContainer> createState() => _ShimmerPulseContainerState();
}

class _ShimmerPulseContainerState extends State<ShimmerPulseContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Color?> _colorAnimation;
  late Animation<Color?> _borderColorAnimation;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _colorAnimation = ColorTween(
      begin: Colors.white,
      end: theme.colorScheme.surfaceContainerLow,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _borderColorAnimation = ColorTween(
      begin: theme.colorScheme.outlineVariant,
      end: const Color(0xFFb1c5ff),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: _colorAnimation.value,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: _borderColorAnimation.value ?? Colors.transparent,
                width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFb1c5ff)
                    .withValues(alpha: 0.15 * _controller.value),
                blurRadius: 20,
                spreadRadius: 0,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class PulseRingIcon extends StatefulWidget {
  final IconData icon;
  const PulseRingIcon({super.key, required this.icon});
  @override
  State<PulseRingIcon> createState() => _PulseRingIconState();
}

class _PulseRingIconState extends State<PulseRingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.scale(
                scale: 0.8 + (_controller.value * 0.7),
                child: Opacity(
                  opacity: 0.5 * (1.0 - _controller.value),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child:
                Icon(widget.icon, color: theme.colorScheme.onPrimary, size: 28),
          ),
        ],
      ),
    );
  }
}
