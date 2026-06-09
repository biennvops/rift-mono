import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_flutter/src/ipc/bounded_line_splitter.dart';

void main() {
  group('BoundedLineSplitter', () {
    test('splits lines correctly including CRLF', () async {
      final splitter = const BoundedLineSplitter(maxLength: 100);
      final stream = Stream.fromIterable([
        'line1\n',
        'line2\r\n',
        'line3'
      ]).transform(splitter);

      final result = await stream.toList();
      expect(result, equals(['line1', 'line2', 'line3']));
    });

    test('ignores empty lines', () async {
      final splitter = const BoundedLineSplitter(maxLength: 100);
      final stream = Stream.fromIterable([
        'line1\n\n\nline2\n'
      ]).transform(splitter);

      final result = await stream.toList();
      expect(result, equals(['line1', 'line2']));
    });

    test('handles partial chunks', () async {
      final splitter = const BoundedLineSplitter(maxLength: 100);
      final stream = Stream.fromIterable([
        'li',
        'ne1\nli',
        'ne2'
      ]).transform(splitter);

      final result = await stream.toList();
      expect(result, equals(['line1', 'line2']));
    });

    test('throws FormatException on exceeding maxLength (OOM guard)', () async {
      final splitter = const BoundedLineSplitter(maxLength: 10);
      final stream = Stream.fromIterable([
        'this_is_a_very_long_line_without_newline'
      ]).transform(splitter);

      expect(() => stream.toList(), throwsA(isA<FormatException>()));
    });
    
    test('tracks byte length instead of code units', () async {
      // 10 bytes limit.
      final splitter = const BoundedLineSplitter(maxLength: 10);
      // '😊' is 4 bytes in UTF-8, 2 code units in UTF-16.
      // '😊😊😊' is 12 bytes.
      final stream = Stream.fromIterable([
        '😊😊😊\n'
      ]).transform(splitter);

      expect(() => stream.toList(), throwsA(isA<FormatException>()));
    });
  });
}
