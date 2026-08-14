import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../src/ipc/json_rpc_client.dart';
import '../widgets/pairing_verification_view.dart';

class PairingScreen extends StatefulWidget {
  final String? initialDeviceId;
  final String? initialEndpointAddress;
  final int? initialEndpointPort;
  final String? initialDisplayName;
  final String? initialPeerPlatform;
  final String? initialPeerFingerprint;
  final int? initialExpiresInMs;
  final bool initialCanApproveLocally;
  final String? initialStatus;
  final bool autoStart;
  final VoidCallback? onClose;
  final ValueChanged<String>? onCompleted;

  const PairingScreen({
    super.key,
    this.initialDeviceId,
    this.initialEndpointAddress,
    this.initialEndpointPort,
    this.initialDisplayName,
    this.initialPeerPlatform,
    this.initialPeerFingerprint,
    this.initialExpiresInMs,
    this.initialCanApproveLocally = false,
    this.initialStatus,
    this.autoStart = false,
    this.onClose,
    this.onCompleted,
  });

  const PairingScreen.forDiscoveredPeer({
    super.key,
    required String deviceId,
    String? displayName,
    String? platform,
    this.onClose,
    this.onCompleted,
  })  : initialDeviceId = deviceId,
        initialEndpointAddress = null,
        initialEndpointPort = null,
        initialDisplayName = displayName,
        initialPeerPlatform = platform,
        initialPeerFingerprint = null,
        initialExpiresInMs = null,
        initialCanApproveLocally = false,
        initialStatus = null,
        autoStart = true;

  const PairingScreen.forEndpoint({
    super.key,
    required String address,
    required int port,
    String? displayName,
    this.onClose,
    this.onCompleted,
  })  : initialDeviceId = null,
        initialEndpointAddress = address,
        initialEndpointPort = port,
        initialDisplayName = displayName,
        initialPeerPlatform = null,
        initialPeerFingerprint = null,
        initialExpiresInMs = null,
        initialCanApproveLocally = false,
        initialStatus = null,
        autoStart = true;

  const PairingScreen.incoming({
    super.key,
    required String deviceId,
    required String fingerprint,
    String? displayName,
    String? platform,
    int? expiresInMs,
    this.onClose,
    this.onCompleted,
  })  : initialDeviceId = deviceId,
        initialEndpointAddress = null,
        initialEndpointPort = null,
        initialDisplayName = displayName,
        initialPeerPlatform = platform,
        initialPeerFingerprint = fingerprint,
        initialExpiresInMs = expiresInMs,
        initialCanApproveLocally = true,
        initialStatus = 'Incoming pairing request',
        autoStart = false;

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
  String? _peerPlatform;
  String? _localDeviceId;
  String? _localDisplayName;
  String? _localPlatform;
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

  void _closeScreen() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

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
    if (_localFingerprint != null &&
        _localFingerprint!.isNotEmpty &&
        _localDeviceId != null &&
        _localDeviceId!.isNotEmpty) {
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
        if (!mounted || result is! Map) return;
        setState(() {
          final fingerprint = result['fingerprint']?.toString();
          if (fingerprint != null && fingerprint.isNotEmpty) {
            _localFingerprint ??= fingerprint;
          }
          _localDeviceId = result['deviceId']?.toString() ?? _localDeviceId;
          _localDisplayName =
              result['displayName']?.toString() ?? _localDisplayName;
          _localPlatform = result['platform']?.toString() ?? _localPlatform;
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
    _peerPlatform = widget.initialPeerPlatform;
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
      final eventDeviceId = event['deviceId']?.toString();
      if (eventDeviceId == null || eventDeviceId.isEmpty) return;
      if (_deviceId != null && eventDeviceId != _deviceId) return;
      setState(() {
        _deviceId = eventDeviceId;
        _displayName = event['displayName']?.toString() ?? _deviceId;
        _peerPlatform = event['platform']?.toString() ?? _peerPlatform;
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
          _closeScreen();
        }
      }
    });
  }

  Future<void> _handlePairingCompleted() async {
    if (!mounted || _isClosingAfterCompletion) return;
    _isClosingAfterCompletion = true;
    final deviceId = _deviceId;
    if (deviceId != null && widget.onCompleted != null) {
      setState(() {
        _status = 'Pairing complete';
        _busy = false;
        _hasActivePairingFlow = false;
        _canApproveLocally = false;
      });
      widget.onCompleted!(deviceId);
      return;
    }
    _closeScreen();
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
        _peerPlatform = result['platform']?.toString() ?? _peerPlatform;
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
        _peerPlatform = result['platform']?.toString() ?? _peerPlatform;
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
        _closeScreen();
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

  @override
  Widget build(BuildContext context) {
    final hasExpired =
        (_remainingSeconds ?? 1) == 0 && !_isClosingAfterCompletion;
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
    final route = ModalRoute.of(context);
    final isDialogOrEmbedded = route is PopupRoute || widget.onClose != null;
    final isMobile = MediaQuery.sizeOf(context).width < 680;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          if (!isDialogOrEmbedded)
            Positioned.fill(
              child: ColoredBox(color: Theme.of(context).colorScheme.surface),
            ),
          Center(
            child: Padding(
              padding: EdgeInsets.all(isMobile ? 12 : 24),
              child: PairingVerificationView(
                localIdentity: PairingIdentityPresentation(
                  label: 'This Device',
                  displayName: _localDisplayName ?? 'This Device',
                  deviceId: _localDeviceId,
                  platform: _localPlatform,
                  fingerprint: _localFingerprint,
                ),
                peerIdentity: PairingIdentityPresentation(
                  label: 'Other Device',
                  displayName: _displayName ?? _deviceId ?? 'Other Device',
                  deviceId: _deviceId,
                  platform: _peerPlatform,
                  fingerprint: _peerFingerprint,
                ),
                status: _status,
                error: _error,
                remainingSeconds: _remainingSeconds,
                hasActivePairing: _hasActivePairingFlow,
                isRecipient: _isRecipientFlow,
                busy: _busy,
                expired: hasExpired,
                approveEnabled: canApprove && _canApproveDelay,
                approveDelayComplete: _canApproveDelay,
                canReject: canReject,
                onApprove: _approvePairing,
                onReject: _rejectPairing,
                onClose: _closeScreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
