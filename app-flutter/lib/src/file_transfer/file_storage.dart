import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const MethodChannel _androidShellChannel = MethodChannel('rift/android/shell');
const MethodChannel _iosDocumentsChannel = MethodChannel('rift/ios/documents');

String sanitizeIncomingFileName(String fileName) {
  final segments = fileName
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  final basename = segments.isEmpty ? null : segments.last;
  final cleaned =
      (basename ?? fileName).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  if (cleaned.isEmpty || RegExp(r'^\.+$').hasMatch(cleaned)) {
    return 'incoming.bin';
  }
  return cleaned;
}

String joinPlatformPath(String a, String b) {
  if (a.endsWith(Platform.pathSeparator)) {
    return '$a$b';
  }
  return '$a${Platform.pathSeparator}$b';
}

String? selectLinuxIncomingDownloadsPath({
  required String? xdgDownloadsPath,
  required String? homePath,
}) {
  if (xdgDownloadsPath != null &&
      xdgDownloadsPath.trim().isNotEmpty &&
      xdgDownloadsPath.startsWith('/')) {
    return xdgDownloadsPath;
  }

  if (homePath == null ||
      homePath.trim().isEmpty ||
      !homePath.startsWith('/')) {
    return null;
  }

  return homePath.endsWith('/')
      ? '${homePath}Downloads'
      : '$homePath/Downloads';
}

Future<Directory?> resolveIncomingDownloadsDirectory() async {
  if (Platform.isIOS) {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(joinPlatformPath(documents.path, 'Downloads'));
  }

  try {
    if (Platform.isAndroid) {
      final publicDownloadsPath =
          await _androidShellChannel.invokeMethod<String>(
        'getPublicDownloadsDirectory',
      );
      if (publicDownloadsPath != null &&
          publicDownloadsPath.trim().isNotEmpty) {
        return Directory(publicDownloadsPath);
      }
    }

    final downloads = await getDownloadsDirectory();
    if (Platform.isLinux) {
      final path = selectLinuxIncomingDownloadsPath(
        xdgDownloadsPath: downloads?.path,
        homePath: Platform.environment['HOME'],
      );
      return path == null ? null : Directory(path);
    }
    if (downloads != null) {
      return downloads;
    }
  } catch (_) {
    if (Platform.isLinux) {
      final path = selectLinuxIncomingDownloadsPath(
        xdgDownloadsPath: null,
        homePath: Platform.environment['HOME'],
      );
      return path == null ? null : Directory(path);
    }
  }

  try {
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        return Directory(
          joinPlatformPath(
            external.parent.parent.parent.parent.path,
            'Download',
          ),
        );
      }
    }
  } catch (_) {
    // Fall through to final fallback.
  }

  if (Platform.isAndroid || Platform.isLinux) {
    return null;
  }

  try {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(joinPlatformPath(docs.path, 'Downloads'));
  } catch (_) {
    return null;
  }
}

Future<String?> buildDefaultIncomingFilePath(String fileName) async {
  final downloadsDir = await resolveIncomingDownloadsDirectory();
  if (downloadsDir == null) {
    return null;
  }

  await downloadsDir.create(recursive: true);
  final sanitizedFileName = sanitizeIncomingFileName(fileName);
  var candidate = File(joinPlatformPath(downloadsDir.path, sanitizedFileName));
  if (!candidate.existsSync()) {
    return candidate.path;
  }

  final dotIndex = sanitizedFileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0 && dotIndex < sanitizedFileName.length - 1;
  final stem = hasExtension
      ? sanitizedFileName.substring(0, dotIndex)
      : sanitizedFileName;
  final extension = hasExtension ? sanitizedFileName.substring(dotIndex) : '';

  for (var i = 1; i <= 999; i += 1) {
    candidate =
        File(joinPlatformPath(downloadsDir.path, '$stem ($i)$extension'));
    if (!candidate.existsSync()) {
      return candidate.path;
    }
  }

  return candidate.path;
}

bool shouldRevealCompletedTransferDestination() {
  if (Platform.isAndroid) {
    return false;
  }

  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

Future<void> openFilePath(String path) async {
  if (path.trim().isEmpty) {
    throw const FileSystemException('Path is empty.');
  }

  if (Platform.isAndroid) {
    final opened = await _androidShellChannel.invokeMethod<bool>(
      'openFile',
      <String, Object?>{'path': path},
    );
    if (opened != true) {
      throw FileSystemException('Android could not open file.', path);
    }
    return;
  }

  if (Platform.isIOS) {
    final opened = await _iosDocumentsChannel.invokeMethod<bool>(
      'previewFile',
      <String, Object?>{'path': path},
    );
    if (opened != true) {
      throw FileSystemException('iOS could not preview file.', path);
    }
    return;
  }

  if (Platform.isWindows) {
    await Process.run('cmd', <String>['/c', 'start', '', path],
        runInShell: true);
    return;
  }

  if (Platform.isMacOS) {
    await Process.run('open', <String>[path]);
    return;
  }

  if (Platform.isLinux) {
    await Process.run('xdg-open', <String>[path]);
    return;
  }

  throw UnsupportedError('Open file is not supported on this platform.');
}

Future<void> exportFilePath(String path) async {
  if (path.trim().isEmpty) {
    throw const FileSystemException('Path is empty.');
  }
  if (!Platform.isIOS) {
    throw UnsupportedError('Export file is not supported on this platform.');
  }

  final exported = await _iosDocumentsChannel.invokeMethod<bool>(
    'exportFile',
    <String, Object?>{'path': path},
  );
  if (exported != true) {
    throw FileSystemException('iOS could not export file.', path);
  }
}

Future<void> showFileInFolder(String path) async {
  if (path.trim().isEmpty) {
    throw const FileSystemException('Path is empty.');
  }

  if (Platform.isWindows) {
    if (path.contains(',')) {
      final parent = File(path).parent.path;
      await Process.run('explorer.exe', <String>[parent]);
      return;
    }

    await Process.run('explorer.exe', <String>['/select,$path']);
    return;
  }

  if (Platform.isMacOS) {
    await Process.run('open', <String>['-R', path]);
    return;
  }

  if (Platform.isLinux) {
    final parent = File(path).parent.path;
    await Process.run('xdg-open', <String>[parent]);
    return;
  }

  throw UnsupportedError('Show in folder is not supported on this platform.');
}
