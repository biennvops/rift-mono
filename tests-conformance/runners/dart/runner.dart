import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final manifestFile = File('$root/testcases/manifest.json');
  final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final suites = (manifest['suites'] as List).cast<String>();

  var passed = 0;
  var failed = 0;

  for (final suiteFile in suites) {
    final file = File('$root/testcases/$suiteFile');
    final suite = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final suiteName = suite['suite'] as String;
    final testCases = (suite['testCases'] as List).cast<Map>().map((e) => Map<String, dynamic>.from(e));

    for (final testCase in testCases) {
      final id = testCase['id'] as String;
      try {
        await _runCase(root, suiteName, testCase);
        stdout.writeln('PASS $suiteName/$id');
        passed++;
      } catch (e) {
        stderr.writeln('FAIL $suiteName/$id: $e');
        failed++;
      }
    }
  }

  stdout.writeln('Summary: $passed passed, $failed failed');
  if (failed > 0) {
    exitCode = 1;
  }
}

Future<void> _runCase(
  String root,
  String suiteName,
  Map<String, dynamic> testCase,
) async {
  switch (suiteName) {
    case 'identity-derivation':
      _runIdentityDerivation(testCase);
      return;
    case 'extension-der':
      _runExtensionDer(testCase);
      return;
    case 'certificate-parsing':
      await _runCertificateParsing(root, testCase);
      return;
    case 'clipboard-hash':
      _runClipboardHash(testCase);
      return;
    case 'envelope-validation':
      _runEnvelopeValidation(testCase);
      return;
    case 'notification-sync':
      _runNotificationSync(testCase);
      return;
    default:
      throw UnsupportedError('Unknown conformance suite: $suiteName');
  }
}

void _runIdentityDerivation(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final pubKey = _hexToBytes(input['ed25519PublicKeyHex'] as String);
  final hash = sha256.convert(pubKey).bytes;
  final base32 = Base32Utils.encode(Uint8List.fromList(hash)).toLowerCase();
  final deviceId = 'rift-${base32.substring(0, 32)}';
  final fingerprint = _formatFingerprint(Uint8List.fromList(hash));

  _expectEquals(_bytesToHex(hash), expected['sha256Hex']);
  _expectEquals(base32, expected['base32']);
  _expectEquals(deviceId, expected['deviceId']);
  _expectEquals(fingerprint, expected['fingerprint']);
}

void _runExtensionDer(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final pubKey = _hexToBytes(input['ed25519PublicKeyHex'] as String);
  final seq = RiftCertBuilder.createEd25519Extension(pubKey);
  final outerOctet = seq.elements[1];

  _expectEquals(_bytesToHex(RiftCertBuilder.riftCustomOidBytes), expected['oidHex']);
  _expectEquals(_bytesToHex(outerOctet.valueBytes()), expected['innerExtnValueHex']);
  _expectEquals(_bytesToHex(outerOctet.encodedBytes), expected['outerExtnValueHex']);
  _expectEquals(_bytesToHex(seq.encodedBytes), expected['completeSequenceHex']);
}

Future<void> _runCertificateParsing(String root, Map<String, dynamic> testCase) async {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final relativeFile = input['file'] as String;
  final file = File(_resolveRelative(root, 'testcases', relativeFile));
  final der = await file.readAsBytes();

  try {
    final key = RiftCertDecoder.extractEd25519PublicKeyFromDer(Uint8List.fromList(der));
    _expectEquals(expected['result'], 'accept');
    _expectEquals(_bytesToHex(key), expected['ed25519PublicKeyHex']);
  } on CertificateDecoderException {
    _expectEquals(expected['result'], 'reject');
    _expectEquals(expected['error'], 'AuthenticationFailed');
  }
}

void _runClipboardHash(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final content = utf8.encode(input['contentUtf8'] as String);
  final digest = sha256.convert(content).bytes;

  _expectEquals(content.length, expected['byteSize']);
  _expectEquals(_bytesToHex(digest), expected['sha256Hex']);
  _expectEquals(base64Encode(content), expected['contentBase64']);
}

void _runEnvelopeValidation(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final json = Map<String, dynamic>.from(input['json'] as Map);
  final sourceDeviceId = json['sourceDeviceId'];
  final isValid = sourceDeviceId is String &&
      RegExp(r'^rift-[a-z2-7]{32}$').hasMatch(sourceDeviceId);

  if (isValid) {
    _expectEquals(expected['result'], 'accept');
  } else {
    _expectEquals(expected['result'], 'reject');
    _expectEquals(expected['error'], 'MalformedMessage');
  }
}

void _runNotificationSync(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final payload = Map<String, dynamic>.from(input['payload'] as Map);
  final type = input['type'];
  final authenticatedPeerId = input['authenticatedPeerId'];

  String result = 'accept';
  String? error;
  if (type == 'notification.posted') {
    final requiredFieldsValid =
        payload['notificationId'] is String &&
        payload['sourceDeviceId'] is String &&
        payload['packageName'] is String &&
        payload['appName'] is String &&
        payload['postedAt'] is String &&
        payload['isDismissible'] is bool &&
        payload['isOpenable'] is bool;
    if (!requiredFieldsValid) {
      result = 'reject';
      error = 'MalformedMessage';
    } else if (payload['sourceDeviceId'] != authenticatedPeerId) {
      result = 'reject';
      error = 'Unauthorized';
    } else if (payload['sourcePlatform'] == 'android' &&
        payload['isOpenable'] == true) {
      result = 'reject';
      error = 'ProtocolError';
    }
  } else if (type == 'notification.actionRequest') {
    if (payload['sourceDeviceId'] != input['localDeviceId'] ||
        payload['requestingDeviceId'] != authenticatedPeerId) {
      result = 'reject';
      error = 'Unauthorized';
    } else if (payload['action'] == 'open') {
      result = 'reject';
      error = 'CapabilityUnavailable';
    } else if (payload['action'] != 'dismiss') {
      result = 'reject';
      error = 'ProtocolError';
    }
  } else {
    result = 'reject';
    error = 'ProtocolError';
  }

  _expectEquals(result, expected['result']);
  if (result == 'reject') {
    _expectEquals(error, expected['error']);
  }
}

String _resolveRelative(String root, String fromDir, String relativePath) {
  return Uri.file('$root/$fromDir/')
      .resolve(relativePath)
      .toFilePath();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _formatFingerprint(Uint8List hashBytes) {
  final base32Str = Base32Utils.encode(hashBytes).toUpperCase().replaceAll('=', '');
  final truncated = base32Str.substring(0, 32);
  return truncated
      .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-')
      .substring(0, 39);
}

void _expectEquals(Object? actual, Object? expected) {
  if (actual != expected) {
    throw StateError('expected <$expected> but got <$actual>');
  }
}
