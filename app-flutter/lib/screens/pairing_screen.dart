import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../src/ipc/json_rpc_client.dart';
import 'dart:async';

class PairingScreen extends StatefulWidget {
  final String? initialDeviceId;
  final String? initialDisplayName;
  final bool autoStart;

  const PairingScreen({
    super.key,
    this.initialDeviceId,
    this.initialDisplayName,
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

  @override
  void initState() {
    super.initState();
    _deviceId = widget.initialDeviceId;
    _displayName = widget.initialDisplayName;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindClient();
      if (widget.autoStart && widget.initialDeviceId != null) {
        _startPairing(widget.initialDeviceId!);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
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
        _completed = false;
      });
    });
    _completeSub = client.onPairingComplete.listen((event) {
      if (!mounted || event['deviceId']?.toString() != _deviceId) return;
      setState(() {
        _peerFingerprint ??= event['fingerprint']?.toString();
        _status = 'Pairing complete';
        _error = null;
        _busy = false;
        _completed = true;
        _countdownTimer?.cancel();
        _remainingSeconds = null;
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
        });
      } else if (newState == 'discovered' && !_completed) {
        setState(() {
          _status = 'Pairing closed';
          _busy = false;
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
    final client = context.read<JsonRpcRiftClient>();
    setState(() {
      _busy = true;
      _deviceId = deviceId;
      _status = 'Starting pairing';
      _error = null;
      _completed = false;
    });

    try {
      final result = await client.startPairing(deviceId) as Map;
      if (!mounted) return;
      setState(() {
        _displayName ??= deviceId;
        _localFingerprint = result['fingerprint']?.toString();
        _peerFingerprint = result['peerFingerprint']?.toString();
        _expiresInMs = (result['expiresInMs'] as num?)?.toInt();
        _startCountdown(_expiresInMs);
        _status = 'Confirm fingerprint to continue';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _status = 'Unable to start pairing';
        _busy = false;
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
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
        _countdownTimer?.cancel();
        _remainingSeconds = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Widget _buildFingerprintCard(String label, String? value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SelectableText(value ?? 'Waiting…'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasExpired = (_remainingSeconds != null && _remainingSeconds == 0 && !_completed);
    final canApprove = !_busy && !_completed && !hasExpired && _deviceId != null && _peerFingerprint != null;

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.pairingTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _displayName ?? _deviceId ?? 'No peer selected',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(_status),
          if (_remainingSeconds != null) ...[
            const SizedBox(height: 4),
            Text(
              hasExpired ? 'Expired' : 'Expires in ${_remainingSeconds!}s',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          _buildFingerprintCard('Peer fingerprint', _peerFingerprint),
          _buildFingerprintCard('Local fingerprint', _localFingerprint),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _deviceId != null && !_busy && !_completed
                ? () => _startPairing(_deviceId!)
                : null,
            icon: const Icon(Icons.link),
            label: const Text('Start pairing'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: canApprove ? _approvePairing : null,
                  child: _busy ? const Text('Working…') : const Text('Approve'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: (!_busy && !_completed && _deviceId != null) ? _rejectPairing : null,
                  child: const Text('Reject'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
