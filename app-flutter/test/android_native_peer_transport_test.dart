import 'package:app_flutter/src/ipc/android_native_peer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidNativePeerTransport duplicate connection ownership', () {
    test('retains an existing preferred connection', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: true,
          candidateIsServer: false,
          preferredIsServer: true,
        ),
        isTrue,
      );
    });

    test('replaces an existing non-preferred connection', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: false,
          candidateIsServer: true,
          preferredIsServer: true,
        ),
        isFalse,
      );
    });

    test('retains the first connection when both have the same role', () {
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: false,
          candidateIsServer: false,
          preferredIsServer: true,
        ),
        isTrue,
      );
      expect(
        AndroidNativePeerTransport.shouldKeepExistingPreAuthConnection(
          existingIsServer: true,
          candidateIsServer: true,
          preferredIsServer: true,
        ),
        isTrue,
      );
    });
  });
}
