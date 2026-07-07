import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
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
  bool _completed = false;
  int? _remainingSeconds;
  bool _hasActivePairingFlow = false;
  bool _canApproveLocally = false;
  bool _canApproveDelay = false;

  void _startApproveDelay() {
    setState(() {
      _canApproveDelay = false;
    });
    _approveDelayTimer?.cancel();
    _approveDelayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _hasActivePairingFlow && !_completed) {
        setState(() {
          _canApproveDelay = true;
        });
      }
    });
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
    if (_hasActivePairingFlow) {
      _startApproveDelay();
    }
    _startCountdown(_expiresInMs);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClient();
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
        _localFingerprint = null;
        _expiresInMs = (event['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Incoming pairing request';
        _error = null;
        _busy = false;
        _completed = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = true;
      });
      _startApproveDelay();
    });
    _completeSub = client.onPairingComplete.listen((event) {
      if (!mounted || event['deviceId']?.toString() != _deviceId) return;
      setState(() {
        _peerFingerprint ??= event['fingerprint']?.toString();
        _status = 'Pairing complete';
        _error = null;
        _busy = false;
        _completed = true;
        _hasActivePairingFlow = false;
        _countdownTimer?.cancel();
        _remainingSeconds = null;
        _canApproveLocally = false;
      });
    });
    _trustSub = client.onTrustChanged.listen((event) {
      if (!mounted || event['deviceId']?.toString() != _deviceId) return;
      final newState = event['newState']?.toString();
      if (newState == 'trusted' && !_completed) {
        setState(() {
          _status = 'Trust persisted';
          _error = null;
          _busy = false;
          _hasActivePairingFlow = false;
          _canApproveLocally = false;
        });
      } else if (newState == 'discovered' && !_completed) {
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
      }
    });
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
          if (!_completed) {
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
    if (_busy && _deviceId == deviceId) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _deviceId = deviceId;
      _status = 'Starting pairing';
      _error = null;
      _completed = false;
      _hasActivePairingFlow = false;
      _canApproveLocally = false;
    });

    try {
      final result = await client.startPairing(deviceId) as Map;
      if (!mounted) return;
      setState(() {
        _deviceId = result['deviceId']?.toString() ?? deviceId;
        _displayName ??= deviceId;
        _localFingerprint = result['fingerprint']?.toString();
        _peerFingerprint = result['peerFingerprint']?.toString();
        _expiresInMs = (result['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Confirm fingerprint to continue';
        _busy = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = false;
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
    if (_busy) {
      return;
    }

    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _status = 'Connecting to $address:$port';
      _error = null;
      _completed = false;
      _hasActivePairingFlow = false;
      _canApproveLocally = false;
    });

    try {
      final result = await client.startPairingByEndpoint(address, port) as Map;
      if (!mounted) return;
      final resolvedDeviceId = result['deviceId']?.toString();
      setState(() {
        _deviceId = resolvedDeviceId;
        _displayName ??= resolvedDeviceId ?? '$address:$port';
        _localFingerprint = result['fingerprint']?.toString();
        _peerFingerprint = result['peerFingerprint']?.toString();
        _expiresInMs = (result['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Confirm fingerprint to continue';
        _busy = false;
        _hasActivePairingFlow = true;
        _canApproveLocally = false;
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

  List<String> _getWordList(String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) {
      return List.filled(8, 'Waiting');
    }
    final mockWords = [
      'Apple', 'Banana', 'Cherry', 'Delta', 'Echo', 'Foxtrot', 'Golf', 'Hotel',
      'India', 'Juliett', 'Kilo', 'Lima', 'Mike', 'November', 'Oscar', 'Papa'
    ];
    List<String> words = [];
    final clean = fingerprint.replaceAll(' ', '');
    for (int i = 0; i < 8; i++) {
      if (i < clean.length) {
        final code = clean.codeUnitAt(i);
        words.add(mockWords[code % mockWords.length]);
      } else {
        words.add(mockWords[i % mockWords.length]);
      }
    }
    return words;
  }

  String _formatFingerprint(String? fp) {
    if (fp == null) return 'WAITING...';
    final clean = fp.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return fp;
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 4) {
      chunks.add(clean.substring(i, (i + 4) > clean.length ? clean.length : i + 4));
    }
    return chunks.join(' ');
  }

  Widget _buildFingerprintBlock({
    required ThemeData theme,
    required String title,
    required IconData icon,
    required Color primaryColor,
    required Color primaryContainer,
    required Color onPrimaryContainer,
    required String? fingerprint,
  }) {
    final words = _getWordList(fingerprint);
    final rawFp = _formatFingerprint(fingerprint);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: primaryColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: onPrimaryContainer),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: onPrimaryContainer, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3,
                  ),
                  itemCount: 8,
                  itemBuilder: (context, index) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '0${index + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                        ),
                        Text(
                          words[index],
                          style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.bold),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  width: double.infinity,
                  child: Text(
                    rawFp,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatFingerprintWithColons(String? fp) {
    if (fp == null) return 'WAITING...';
    final clean = fp.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.isEmpty) return fp;
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 2) {
      chunks.add(clean.substring(i, (i + 2) > clean.length ? clean.length : i + 2));
    }
    return chunks.join(':');
  }

  Widget _buildSuccessState(ThemeData theme) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.2,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -1),
                    radius: 1.0,
                    colors: [
                      theme.colorScheme.secondaryContainer,
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 96,
                    width: 96,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.verified_user,
                            size: 32,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Thiết bị đã kết nối',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      children: [
                        const TextSpan(text: 'Kênh truyền tin đã được thiết lập an toàn với '),
                        TextSpan(
                          text: _displayName ?? _deviceId ?? 'Unknown',
                          style: TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.bold),
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.desktop_windows, color: theme.colorScheme.outline),
                                const SizedBox(width: 8),
                                Text(
                                  _displayName ?? _deviceId ?? 'Unknown',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Icon(Icons.verified, color: theme.colorScheme.secondary),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.key, size: 14, color: theme.colorScheme.onSurfaceVariant),
                                  const SizedBox(width: 4),
                                  Text(
                                    'ACTIVE FINGERPRINT',
                                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _formatFingerprintWithColons(_peerFingerprint),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Bắt đầu ngay', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurface,
                        side: BorderSide(color: theme.colorScheme.outline),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Về danh sách', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_completed) {
      return _buildSuccessState(theme);
    }
    final hasExpired = (_remainingSeconds != null && _remainingSeconds == 0 && !_completed);
    final canApprove = !_busy &&
        !_completed &&
        !hasExpired &&
        _hasActivePairingFlow &&
        _canApproveLocally &&
        _deviceId != null &&
        _peerFingerprint != null;
    final canReject = !_busy && !_completed && _deviceId != null && _hasActivePairingFlow;

    final approveEnabled = canApprove && _canApproveDelay;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Pairing with ${_displayName ?? _deviceId ?? 'Unknown'}',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.primary,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
      ),
      body: !_hasActivePairingFlow
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_busy) const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_status, style: theme.textTheme.bodyLarge),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ]
                ],
              ),
            )
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  children: [
                    Text('Compare fingerprints', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      'Ensure both screens display the exact same words and codes.',
                      style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (hasExpired) ...[
                      const SizedBox(height: 8),
                      Text('Expired', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
                    ] else if (_remainingSeconds != null) ...[
                      const SizedBox(height: 8),
                      Text('Expires in ${_remainingSeconds!}s', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 24),
                    _buildFingerprintBlock(
                      theme: theme,
                      title: "This device's fingerprint",
                      icon: Icons.smartphone,
                      primaryColor: theme.colorScheme.primary,
                      primaryContainer: theme.colorScheme.primaryContainer,
                      onPrimaryContainer: theme.colorScheme.onPrimaryContainer,
                      fingerprint: _localFingerprint,
                    ),
                    const SizedBox(height: 24),
                    _buildFingerprintBlock(
                      theme: theme,
                      title: "${_displayName ?? 'Peer'}'s fingerprint",
                      icon: Icons.desktop_windows,
                      primaryColor: theme.colorScheme.secondary,
                      primaryContainer: theme.colorScheme.secondaryContainer,
                      onPrimaryContainer: theme.colorScheme.onSecondaryContainer,
                      fingerprint: _peerFingerprint,
                    ),
                  ],
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: canReject ? _rejectPairing : null,
                          style: TextButton.styleFrom(
                            backgroundColor: theme.colorScheme.error,
                            foregroundColor: theme.colorScheme.onError,
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        if (_canApproveLocally)
                          ElevatedButton(
                            onPressed: approveEnabled ? _approvePairing : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              elevation: 0,
                            ),
                            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 16.0),
                            child: Text(
                              'Waiting for peer...',
                              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline),
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
