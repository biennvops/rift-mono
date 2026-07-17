import 'dart:async';

import 'package:daemon_dart/src/network/peer_write_gate.dart';
import 'package:test/test.dart';

void main() {
  group('PeerWriteGate', () {
    test('serializes concurrent operations', () async {
      final gate = PeerWriteGate();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondEntered = false;
      var overlapDetected = false;
      var activeWriters = 0;

      final first = gate.run(() async {
        activeWriters += 1;
        if (activeWriters != 1) {
          overlapDetected = true;
        }
        firstStarted.complete();
        await releaseFirst.future;
        activeWriters -= 1;
      });

      await firstStarted.future;

      final second = gate.run(() async {
        secondEntered = true;
        activeWriters += 1;
        if (activeWriters != 1) {
          overlapDetected = true;
        }
        activeWriters -= 1;
      });

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(secondEntered, isFalse);

      releaseFirst.complete();
      await Future.wait([first, second]);

      expect(secondEntered, isTrue);
      expect(overlapDetected, isFalse);
    });
  });
}
