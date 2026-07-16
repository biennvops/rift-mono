import 'package:app_flutter/src/ipc/unix_socket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'macOS candidate paths prefer daemon-cs TMPDIR socket over legacy /tmp fallback',
      () {
    final paths = candidateSocketPathsForTesting(
      environment: const {
        'TMPDIR': '/var/folders/example/T/',
      },
    );

    expect(paths, [
      '/var/folders/example/T//rift-daemon/v0.1.sock',
      '/tmp/rift-daemon-501/v0.1.sock',
    ]);
  });

  test('explicit configured socket path is tried before runtime-derived paths',
      () {
    final paths = candidateSocketPathsForTesting(
      configured: '/tmp/custom-rift.sock',
      environment: const {
        'TMPDIR': '/var/folders/example/T/',
      },
      uidOverride: '501',
    );

    expect(paths, [
      '/tmp/custom-rift.sock',
      '/var/folders/example/T//rift-daemon/v0.1.sock',
      '/tmp/rift-daemon-501/v0.1.sock',
    ]);
  });

  test('per-user tmp fallback is included when uid is available', () {
    final paths = candidateSocketPathsForTesting(
      environment: const {},
      uidOverride: '501',
    );

    expect(paths, [
      '/tmp/rift-daemon-501/v0.1.sock',
    ]);
  });
}
