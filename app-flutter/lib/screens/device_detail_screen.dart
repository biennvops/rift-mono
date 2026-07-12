import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../src/ipc/json_rpc_client.dart';
import 'dart:async';
import 'dart:io';

class DeviceDetailScreen extends StatefulWidget {
  final Map<String, dynamic> peer;
  final bool isOnline;

  const DeviceDetailScreen({super.key, required this.peer, required this.isOnline});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  late Map<String, dynamic> peer;
  late bool isOnline;
  bool _isLoadingFileOffers = false;
  bool _isSendingFile = false;
  List<Map<String, dynamic>> _incomingFileOffers = [];
  StreamSubscription<Map<String, dynamic>>? _fileOfferSub;
  StreamSubscription<Map<String, dynamic>>? _fileCompletedSub;
  StreamSubscription<Map<String, dynamic>>? _fileFailedSub;

  @override
  void initState() {
    super.initState();
    peer = widget.peer;
    isOnline = widget.isOnline;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadIncomingFileOffers();
      _bindFileTransferNotifications();
    });
  }

  @override
  void dispose() {
    _fileOfferSub?.cancel();
    _fileCompletedSub?.cancel();
    _fileFailedSub?.cancel();
    super.dispose();
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

  String _formatTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return 'Unavailable';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    final yyyy = parsed.year.toString().padLeft(4, '0');
    final mm = parsed.month.toString().padLeft(2, '0');
    final dd = parsed.day.toString().padLeft(2, '0');
    final hh = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    final sec = parsed.second.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min:$sec';
  }

  void _bindFileTransferNotifications() {
    final client = context.read<JsonRpcRiftClient>();
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    _fileOfferSub = client.onFileOffer.listen((event) {
      if (event['sourceDeviceId']?.toString() == deviceId && mounted) {
        _loadIncomingFileOffers();
      }
    });
    _fileCompletedSub = client.onFileTransferCompleted.listen((event) {
      if (event['peerDeviceId']?.toString() == deviceId && mounted) {
        _loadIncomingFileOffers();
      }
    });
    _fileFailedSub = client.onFileTransferFailed.listen((event) {
      if (event['peerDeviceId']?.toString() == deviceId && mounted) {
        _loadIncomingFileOffers();
      }
    });
  }

  Future<void> _loadIncomingFileOffers() async {
    final deviceId = peer['deviceId']?.toString();
    if (!mounted || deviceId == null || deviceId.isEmpty) {
      return;
    }

    setState(() {
      _isLoadingFileOffers = true;
    });

    try {
      final client = context.read<JsonRpcRiftClient>();
      final result = await client.listIncomingFileOffers() as Map;
      final offers = List<Map<String, dynamic>>.from(
        (result['offers'] as List? ?? const <dynamic>[]).map(
          (offer) => Map<String, dynamic>.from(offer as Map),
        ),
      ).where((offer) => offer['sourceDeviceId']?.toString() == deviceId).toList(growable: false);

      if (!mounted) return;
      setState(() {
        _incomingFileOffers = offers;
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingFileOffers = false;
        });
      }
    }
  }

  Future<bool> _showRevokeBottomSheet(String displayName, String fingerprint) async {
    final theme = Theme.of(context);
    final shortFingerprint = fingerprint.length > 16 
        ? '${fingerprint.substring(0, 16)}...' 
        : fingerprint;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 48,
                height: 6,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              // Warning Icon
              Icon(
                Icons.warning,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              // Title
              Text(
                'Quên thiết bị $displayName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              // Warning Text
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Thiết bị sẽ bị ngắt kết nối và xóa khỏi danh sách tin cậy. Bạn sẽ phải xác nhận lại (pair) nếu muốn kết nối lại trong tương lai.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Technical Detail Box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(Icons.fingerprint, color: theme.colorScheme.outline),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TARGET KEY',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          shortFingerprint,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Buttons
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text(
                    'Xóa thiết bị',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurface,
                    side: BorderSide(color: theme.colorScheme.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Hủy',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  Future<bool> _showBlockBottomSheet(String displayName) async {
    final theme = Theme.of(context);

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 48,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Block Icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.block,
                  color: theme.colorScheme.error,
                  size: 24,
                ),
              ),
              const SizedBox(height: 16),
              // Title
              Text(
                'Chặn $displayName?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              // Content Text
              Text(
                'Thiết bị bị chặn vĩnh viễn. Mọi kết nối từ khóa Ed25519 này sẽ bị từ chối tự động.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              // Buttons
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Chặn vĩnh viễn',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Hủy',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  Future<void> _revokeTrust() async {
    final deviceId = peer['deviceId']?.toString();
    final displayName = peer['displayName']?.toString() ?? deviceId;
    final fingerprint = peer['fingerprint']?.toString() ?? 'Unknown';
    if (deviceId == null) return;
    
    final client = context.read<JsonRpcRiftClient>();
    final confirmed = await _showRevokeBottomSheet(displayName ?? 'Unknown', fingerprint);
    if (!confirmed) return;
    
    try {
      await client.revokeTrust(deviceId, 'User revoked from Device Detail');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _blockPeer() async {
    final deviceId = peer['deviceId']?.toString();
    final displayName = peer['displayName']?.toString() ?? deviceId;
    if (deviceId == null) return;
    
    final confirmed = await _showBlockBottomSheet(displayName ?? 'Unknown');
    if (!confirmed) return;
    
    try {
      // Block is not yet implemented in the JsonRpcRiftClient.
      // await client.blockPeer(deviceId);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Block not implemented in daemon yet')));
      // if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<Map<String, String>?> _showSendFileFallbackDialog() async {
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    final typeController =
        TextEditingController(text: 'application/octet-stream');
    String? validationError;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final path = pathController.text.trim();
              final name = nameController.text.trim();
              final type = typeController.text.trim();
              if (path.isEmpty) {
                setDialogState(() {
                  validationError = 'Enter a local file path.';
                });
                return;
              }
              if (!File(path).existsSync()) {
                setDialogState(() {
                  validationError = 'That file path does not exist.';
                });
                return;
              }
              Navigator.of(dialogContext).pop({
                'localPath': path,
                'fileName': name,
                'mediaType': type,
              });
            }

            return AlertDialog(
              title: const Text('Send File'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: pathController,
                      decoration: const InputDecoration(
                        labelText: 'Local path',
                        hintText: r'C:\Users\you\Downloads\example.pdf',
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display file name (optional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: typeController,
                      decoration: const InputDecoration(
                        labelText: 'Media type',
                      ),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: submit,
                  child: const Text('Send'),
                ),
              ],
            );
          },
        );
      },
    );

    return result;
  }

  Future<String?> _showDestinationFallbackDialog(String suggestedFileName) async {
    final destinationController = TextEditingController(
      text: await _defaultDestinationPath(suggestedFileName) ??
          (Platform.isWindows
              ? r'C:\Users\Public\Downloads\' + suggestedFileName
              : '/tmp/$suggestedFileName'),
    );
    String? validationError;

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final path = destinationController.text.trim();
              if (path.isEmpty) {
                setDialogState(() {
                  validationError = 'Enter a destination path.';
                });
                return;
              }
              Navigator.of(dialogContext).pop(path);
            }

            return AlertDialog(
              title: const Text('Save Incoming File'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: destinationController,
                      decoration: const InputDecoration(
                        labelText: 'Destination path',
                      ),
                      autofocus: true,
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: submit,
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        );
      },
    );

    return result;
  }

  Future<Map<String, String>?> _pickSendFileRequest() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
        lockParentWindow: true,
      );
      final files = result?.files;
      final picked =
          files != null && files.isNotEmpty ? files.first : null;
      final path = picked?.path;
      if (picked == null || path == null || path.isEmpty) {
        return null;
      }

      return {
        'localPath': path,
        'fileName': picked.name,
        'mediaType': _guessMediaTypeFromName(picked.name),
      };
    } catch (_) {
      return _showSendFileFallbackDialog();
    }
  }

  Future<String?> _pickDestinationPath(String suggestedFileName) async {
    try {
      final defaultPath = await _defaultDestinationPath(suggestedFileName);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save incoming file',
        fileName: suggestedFileName,
        initialDirectory:
            defaultPath == null ? null : File(defaultPath).parent.path,
        lockParentWindow: true,
      );
      if (path == null || path.isEmpty) {
        return null;
      }
      return path;
    } catch (_) {
      return _showDestinationFallbackDialog(suggestedFileName);
    }
  }

  Future<String?> _defaultDestinationPath(String suggestedFileName) async {
    Directory? baseDir;
    try {
      baseDir = await getDownloadsDirectory();
    } catch (_) {
      baseDir = null;
    }

    if (baseDir == null) {
      try {
        if (Platform.isAndroid) {
          final external = await getExternalStorageDirectory();
          if (external != null) {
            baseDir = Directory(
              '${external.parent.parent.parent.parent.path}${Platform.pathSeparator}Download',
            );
          }
        }
      } catch (_) {
        baseDir = null;
      }
    }

    baseDir ??= Platform.isWindows
        ? Directory(r'C:\Users\Public\Downloads')
        : Directory('/tmp');

    final cleaned =
        suggestedFileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    final fileName = cleaned.isEmpty ? 'incoming.bin' : cleaned;
    return '${baseDir.path}${Platform.pathSeparator}$fileName';
  }

  String _guessMediaTypeFromName(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.endsWith('.txt')) return 'text/plain';
    if (normalized.endsWith('.json')) return 'application/json';
    if (normalized.endsWith('.pdf')) return 'application/pdf';
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (normalized.endsWith('.png')) return 'image/png';
    if (normalized.endsWith('.gif')) return 'image/gif';
    if (normalized.endsWith('.mp4')) return 'video/mp4';
    if (normalized.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<void> _sendFile() async {
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;

    final dialogResult = await _pickSendFileRequest();
    if (dialogResult == null) return;

    setState(() {
      _isSendingFile = true;
    });

    try {
      final client = context.read<JsonRpcRiftClient>();
      final result = await client.offerFile(
        targetDeviceId: deviceId,
        localPath: dialogResult['localPath']!,
        fileName: dialogResult['fileName']?.isNotEmpty == true
            ? dialogResult['fileName']
            : null,
        mediaType: dialogResult['mediaType']?.isNotEmpty == true
            ? dialogResult['mediaType']
            : null,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Sent file offer ${result['fileName'] ?? dialogResult['localPath']}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingFile = false;
        });
      }
    }
  }

  Future<void> _acceptIncomingOffer(Map<String, dynamic> offer) async {
    final destinationPath = await _pickDestinationPath(
      offer['fileName']?.toString() ?? 'incoming.bin',
    );
    if (destinationPath == null || destinationPath.isEmpty) {
      return;
    }

    try {
      final client = context.read<JsonRpcRiftClient>();
      await client.acceptFileOffer(
        transferId: offer['transferId']?.toString() ?? '',
        destinationPath: destinationPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Accepted ${offer['fileName'] ?? 'file'}')),
      );
      await _loadIncomingFileOffers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
    }
  }

  Future<void> _rejectIncomingOffer(Map<String, dynamic> offer) async {
    try {
      final client = context.read<JsonRpcRiftClient>();
      await client.rejectFileOffer(
        transferId: offer['transferId']?.toString() ?? '',
        failureReason: 'PolicyDenied',
        message: 'User declined from device detail screen',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rejected ${offer['fileName'] ?? 'file'}')),
      );
      await _loadIncomingFileOffers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JsonRpcRiftClient.formatDisplayError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceId = peer['deviceId']?.toString() ?? 'Unknown ID';
    final displayName = peer['displayName']?.toString() ?? deviceId;
    final fingerprint = peer['fingerprint']?.toString() ?? '';
    final trustState = peer['trustState']?.toString() ?? 'trusted';
    final implementationId =
        peer['implementationId']?.toString() ?? 'Unavailable';
    final protocolVersion =
        peer['protocolVersion']?.toString() ?? 'Unavailable';
    final ipAddress =
        peer['lastAddress']?.toString() ?? peer['address']?.toString() ?? 'Unavailable';
    final uptime = peer['sessionUptime']?.toString() ?? 'Unavailable';
    final tlsCipher = peer['tlsCipher']?.toString() ?? 'Unavailable';
    final latency =
        peer['latencyMs'] != null ? '${peer['latencyMs']} ms' : 'Unavailable';
    final pairedAt = _formatTimestamp(peer['pairedAt']?.toString());
    final lastSeenAt = _formatTimestamp(peer['lastSeenAt']?.toString());
    final capabilities = List<String>.from(
      (peer['capabilities'] as List? ?? const <dynamic>[]).map((e) => e.toString()),
    );
    final canTransferFiles =
        trustState == 'trusted' && capabilities.contains('file.transfer');
    final recentEvents = List<Map<String, dynamic>>.from(
      (peer['recentEvents'] as List? ?? const <dynamic>[]).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          displayName,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: theme.colorScheme.outlineVariant, height: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header Section
          Center(
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Icon(Icons.laptop_mac, size: 32, color: theme.colorScheme.onSurface),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.verified, size: 14, color: theme.colorScheme.onSecondaryContainer),
                          const SizedBox(width: 4),
                        Text(
                          trustState.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      children: [
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            color: isOnline ? theme.colorScheme.secondary : theme.colorScheme.outline,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(isOnline ? 'ONLINE' : 'OFFLINE', style: theme.textTheme.labelSmall?.copyWith(color: isOnline ? theme.colorScheme.secondary : theme.colorScheme.outline)),
                      ],
                    )
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  trustState == 'trusted'
                      ? 'Trusted since $pairedAt'
                      : 'Last seen $lastSeenAt',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Identity Bento
          Text('IDENTITY', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device ID', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(deviceId, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface)),
                const SizedBox(height: 12),
                Text('Fingerprint', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_formatFingerprintWithColons(fingerprint), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface, letterSpacing: 1.0)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Certificate', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          Text(
                            implementationId,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Protocol', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          Text(
                            protocolVersion,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Session & Capabilities
          Text('SESSION & CAPABILITIES', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Capabilities', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: capabilities.isEmpty
                      ? [
                          Text(
                            'Unavailable',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ]
                      : capabilities.map((capability) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              capability,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          );
                        }).toList(),
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('IP Address', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          Text(ipAddress, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Uptime', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          Text(uptime, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Latency', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    Text(latency, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 12),
                    Text('TLS Cipher', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    Text(tlsCipher, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          Text('FILE TRANSFER', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  canTransferFiles
                      ? 'This peer negotiated the file.transfer capability.'
                      : 'File transfer is unavailable until this peer negotiates file.transfer and is trusted.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: canTransferFiles && !_isSendingFile ? _sendFile : null,
                    icon: _isSendingFile
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file),
                    label: Text(_isSendingFile ? 'Sending...' : 'Send File'),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      'Incoming offers',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (_isLoadingFileOffers)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        onPressed: _loadIncomingFileOffers,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh incoming offers',
                      ),
                  ],
                ),
                if (_incomingFileOffers.isEmpty)
                  Text(
                    'No incoming file offers from this device right now.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Column(
                    children: _incomingFileOffers.map((offer) {
                      final fileName =
                          offer['fileName']?.toString() ?? 'Unknown file';
                      final byteSize = offer['byteSize']?.toString() ?? '0';
                      return Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fileName,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${offer['mediaType'] ?? 'application/octet-stream'} • $byteSize bytes',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => _rejectIncomingOffer(offer),
                                    child: const Text('Reject'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () => _acceptIncomingOffer(offer),
                                    child: const Text('Accept'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(growable: false),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Recent Events
          Text('RECENT EVENTS', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: recentEvents.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No device-specific events are exposed by the daemon yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (int i = 0; i < recentEvents.length; i++) ...[
                        _buildEventRow(
                          recentEvents[i]['timestamp']?.toString() ?? '--:--',
                          recentEvents[i]['eventType']?.toString() ?? 'unknown',
                          theme,
                          recentEvents[i]['outcome']?.toString() == 'success',
                        ),
                        if (i != recentEvents.length - 1)
                          Divider(height: 1, color: theme.colorScheme.outlineVariant),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 32),
          
          // Actions
          OutlinedButton(
            onPressed: _revokeTrust,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              side: BorderSide(color: theme.colorScheme.error),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Xóa thiết bị (Forget)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _blockPeer,
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Chặn', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const SizedBox(height: 8),
          Text(
            'Blocking from this view is pending full daemon support.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildEventRow(String time, String event, ThemeData theme, bool highlight) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(time, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              event,
              style: theme.textTheme.labelMedium?.copyWith(
                color: highlight ? theme.colorScheme.secondary : theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
