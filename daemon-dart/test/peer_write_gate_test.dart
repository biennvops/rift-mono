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

    test('retains exact order across a sustained queue', () async {
      final gate = PeerWriteGate();
      final observed = <int>[];
      final writes = <Future<void>>[];

      for (var i = 0; i < 256; i++) {
        writes.add(
          gate.run(() async {
            if (i.isEven) await Future<void>.delayed(Duration.zero);
            observed.add(i);
          }),
        );
      }
      await Future.wait(writes);

      expect(observed, List<int>.generate(256, (index) => index));
    });

    test('does not reorder a control write queued amid bulk writes', () async {
      final gate = PeerWriteGate();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final observed = <String>[];

      final bulkA = gate.run(() async {
        firstStarted.complete();
        await releaseFirst.future;
        observed.add('bulk-a');
      });
      await firstStarted.future;
      final control = gate.run(() async => observed.add('control-b'));
      final bulkC = gate.run(() async => observed.add('bulk-c'));

      releaseFirst.complete();
      await Future.wait([bulkA, control, bulkC]);

      expect(observed, ['bulk-a', 'control-b', 'bulk-c']);
    });
  });
}
