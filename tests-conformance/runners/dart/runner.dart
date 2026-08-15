import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/daemon.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
import 'package:daemon_dart/src/crypto/cert_builder.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final manifestFile = File('$root/testcases/manifest.json');
  final manifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final suites = (manifest['suites'] as List).cast<String>();

  var passed = 0;
  var failed = 0;

  for (final suiteFile in suites) {
    final file = File('$root/testcases/$suiteFile');
    final suite = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final suiteName = suite['suite'] as String;
    final testCases = (suite['testCases'] as List).cast<Map>().map(
      (e) => Map<String, dynamic>.from(e),
    );

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
    case 'notification-action-correlation':
      _runNotificationActionCorrelation(testCase);
      return;
    case 'media-playback-action-correlation':
      _runMediaPlaybackActionCorrelation(testCase);
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

  _expectEquals(
    _bytesToHex(RiftCertBuilder.riftCustomOidBytes),
    expected['oidHex'],
  );
  _expectEquals(
    _bytesToHex(outerOctet.valueBytes()),
    expected['innerExtnValueHex'],
  );
  _expectEquals(
    _bytesToHex(outerOctet.encodedBytes),
    expected['outerExtnValueHex'],
  );
  _expectEquals(_bytesToHex(seq.encodedBytes), expected['completeSequenceHex']);
}

Future<void> _runCertificateParsing(
  String root,
  Map<String, dynamic> testCase,
) async {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final relativeFile = input['file'] as String;
  final file = File(_resolveRelative(root, 'testcases', relativeFile));
  final der = await file.readAsBytes();

  try {
    final key = RiftCertDecoder.extractEd25519PublicKeyFromDer(
      Uint8List.fromList(der),
    );
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

void _runNotificationSync(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final rawIcon = Map<String, dynamic>.from(input['icon'] as Map);
  final encodedLength = rawIcon['dataBase64Length'];
  if (encodedLength is int) {
    rawIcon['dataBase64'] = 'A' * encodedLength;
    rawIcon.remove('dataBase64Length');
  }

  final normalized = normalizeNotificationIcon(rawIcon);
  if (expected['result'] == 'accept') {
    if (normalized == null) {
      throw StateError('valid notification icon was dropped');
    }
    _expectEquals(normalized['mediaType'], 'image/png');
    _expectEquals(normalized['byteSize'], rawIcon['byteSize']);
    _expectEquals(normalized['sha256'], rawIcon['sha256']);
  } else if (normalized != null) {
    throw StateError('invalid notification icon was accepted');
  }
  _expectEquals(
    input['notificationAccepted'],
    expected['notificationAccepted'],
  );
}

void _runNotificationActionCorrelation(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final initialRequest = Map<String, dynamic>.from(
    input['initialRequest'] as Map,
  );
  final retryRequest = Map<String, dynamic>.from(input['retryRequest'] as Map);
  final lateResult = Map<String, dynamic>.from(input['lateResult'] as Map);
  final retryResult = Map<String, dynamic>.from(input['retryResult'] as Map);

  _validateNotificationActionPayload(initialRequest, isResult: false);
  _validateNotificationActionPayload(retryRequest, isResult: false);
  _validateNotificationActionPayload(lateResult, isResult: true);
  _validateNotificationActionPayload(retryResult, isResult: true);
  _expectEquals(lateResult['operationId'], initialRequest['operationId']);
  _expectEquals(retryResult['operationId'], retryRequest['operationId']);
  if (initialRequest['operationId'] == retryRequest['operationId']) {
    throw StateError('retry must use a distinct operationId');
  }

  final pending = <String, Map<String, dynamic>>{
    initialRequest['operationId'] as String: initialRequest,
  };
  final states = <String, String>{
    initialRequest['operationId'] as String: 'Expired',
    retryRequest['operationId'] as String: 'Dispatched',
  };
  pending.remove(initialRequest['operationId']);
  pending[retryRequest['operationId'] as String] = retryRequest;

  _applyNotificationActionResult(pending, states, lateResult);
  _expectEquals(
    states[retryRequest['operationId']],
    expected['stateAfterLateResult'],
  );

  _applyNotificationActionResult(pending, states, retryResult);
  _expectEquals(states[retryRequest['operationId']], expected['finalState']);
  _expectEquals(expected['result'], 'accept');
}

void _validateNotificationActionPayload(
  Map<String, dynamic> payload, {
  required bool isResult,
}) {
  for (final field in [
    'operationId',
    'notificationId',
    'sourceDeviceId',
    'requestingDeviceId',
    'action',
  ]) {
    if (payload[field] is! String || (payload[field] as String).isEmpty) {
      throw StateError('$field is required');
    }
  }
  if (payload['action'] != 'open' && payload['action'] != 'dismiss') {
    throw StateError('unknown notification action');
  }
  if (isResult && payload['success'] is! bool) {
    throw StateError('success is required on action results');
  }
}

void _applyNotificationActionResult(
  Map<String, Map<String, dynamic>> pending,
  Map<String, String> states,
  Map<String, dynamic> result,
) {
  final operationId = result['operationId'] as String;
  final request = pending.remove(operationId);
  if (request == null) {
    return;
  }
  for (final field in [
    'notificationId',
    'sourceDeviceId',
    'requestingDeviceId',
    'action',
  ]) {
    _expectEquals(result[field], request[field]);
  }
  states[operationId] = result['success'] == true ? 'Done' : 'Failed';
}

void _runMediaPlaybackActionCorrelation(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  if (input['envelope'] is Map) {
    _runMediaPlaybackActionEnvelope(input, expected);
    return;
  }
  final initialRequest = Map<String, dynamic>.from(
    input['initialRequest'] as Map,
  );
  final retryRequest = Map<String, dynamic>.from(input['retryRequest'] as Map);
  final lateResult = Map<String, dynamic>.from(input['lateResult'] as Map);
  final retryResult = Map<String, dynamic>.from(input['retryResult'] as Map);

  _validateMediaPlaybackActionPayload(initialRequest, isResult: false);
  _validateMediaPlaybackActionPayload(retryRequest, isResult: false);
  _validateMediaPlaybackActionPayload(lateResult, isResult: true);
  _validateMediaPlaybackActionPayload(retryResult, isResult: true);
  _expectEquals(lateResult['operationId'], initialRequest['operationId']);
  _expectEquals(retryResult['operationId'], retryRequest['operationId']);
  if (initialRequest['operationId'] == retryRequest['operationId']) {
    throw StateError('retry must use a distinct operationId');
  }

  final pending = <String, Map<String, dynamic>>{
    initialRequest['operationId'] as String: initialRequest,
  };
  final states = <String, String>{
    initialRequest['operationId'] as String: 'Expired',
    retryRequest['operationId'] as String: 'Dispatched',
  };
  pending.remove(initialRequest['operationId']);
  pending[retryRequest['operationId'] as String] = retryRequest;

  _applyMediaPlaybackActionResult(pending, states, lateResult);
  _expectEquals(
    states[retryRequest['operationId']],
    expected['stateAfterLateResult'],
  );

  _applyMediaPlaybackActionResult(pending, states, retryResult);
  _expectEquals(states[retryRequest['operationId']], expected['finalState']);
  _expectEquals(expected['result'], 'accept');
}

void _runMediaPlaybackActionEnvelope(
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
) {
  final envelope = Map<String, dynamic>.from(input['envelope'] as Map);
  final payload = envelope['payload'] is Map
      ? Map<String, dynamic>.from(envelope['payload'] as Map)
      : <String, dynamic>{};
  final envelopeOperationId = envelope['operationId'];
  final payloadOperationId = payload['operationId'];

  late final String result;
  String? error;
  if (envelopeOperationId is! String ||
      !_isValidMediaOperationId(envelopeOperationId) ||
      payloadOperationId is! String ||
      !_isValidMediaOperationId(payloadOperationId)) {
    result = 'reject';
    error = 'MalformedMessage';
  } else if (envelopeOperationId != payloadOperationId) {
    result = 'reject';
    error = 'ProtocolError';
  } else {
    result = 'accept';
  }

  _expectEquals(result, expected['result']);
  if (result == 'reject') {
    _expectEquals(error, expected['error']);
  }
}

bool _isValidMediaOperationId(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

void _validateMediaPlaybackActionPayload(
  Map<String, dynamic> payload, {
  required bool isResult,
}) {
  for (final field in [
    'operationId',
    'playbackId',
    'sourceDeviceId',
    'requestingDeviceId',
    'action',
  ]) {
    if (payload[field] is! String || (payload[field] as String).isEmpty) {
      throw StateError('$field is required');
    }
  }
  if (!_isValidMediaOperationId(payload['operationId'] as String)) {
    throw StateError('operationId must be a lowercase UUIDv4');
  }
  if (!const {
    'play',
    'pause',
    'togglePlayPause',
    'next',
    'previous',
    'seek',
  }.contains(payload['action'])) {
    throw StateError('unknown media playback action');
  }
  if (isResult && payload['success'] is! bool) {
    throw StateError('success is required on action results');
  }
}

void _applyMediaPlaybackActionResult(
  Map<String, Map<String, dynamic>> pending,
  Map<String, String> states,
  Map<String, dynamic> result,
) {
  final operationId = result['operationId'] as String;
  final request = pending.remove(operationId);
  if (request == null) {
    return;
  }
  for (final field in [
    'playbackId',
    'sourceDeviceId',
    'requestingDeviceId',
    'action',
  ]) {
    _expectEquals(result[field], request[field]);
  }
  states[operationId] = result['success'] == true ? 'Done' : 'Failed';
}

void _runEnvelopeValidation(Map<String, dynamic> testCase) {
  final input = Map<String, dynamic>.from(testCase['input'] as Map);
  final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
  final json = Map<String, dynamic>.from(input['json'] as Map);
  final sourceDeviceId = json['sourceDeviceId'];
  final isValid =
      sourceDeviceId is String &&
      RegExp(r'^rift-[a-z2-7]{32}$').hasMatch(sourceDeviceId);

  if (isValid) {
    _expectEquals(expected['result'], 'accept');
  } else {
    _expectEquals(expected['result'], 'reject');
    _expectEquals(expected['error'], 'MalformedMessage');
  }
}

String _resolveRelative(String root, String fromDir, String relativePath) {
  return Uri.file('$root/$fromDir/').resolve(relativePath).toFilePath();
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
  final base32Str = Base32Utils.encode(
    hashBytes,
  ).toUpperCase().replaceAll('=', '');
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
