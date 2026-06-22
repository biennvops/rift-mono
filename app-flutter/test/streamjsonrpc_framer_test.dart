import 'dart:async';
import 'dart:convert';

import 'package:app_flutter/src/ipc/streamjsonrpc_framer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('streamJsonRpcFramer', () {
    test('parses message when header and body arrive in separate chunks',
        () async {
      final incoming = StreamController<List<int>>();
      final outgoing = StreamController<List<int>>();
      final channel = streamJsonRpcFramer(incoming.stream, outgoing.sink);
      final message = Completer<String>();
      final sub = channel.stream.listen(message.complete);

      final body = '{"jsonrpc":"2.0"}';
      final framed = _frame(body);
      await Future<void>.delayed(Duration.zero);
      incoming.add(framed.sublist(0, 10));
      incoming.add(framed.sublist(10, framed.length - 5));
      incoming.add(framed.sublist(framed.length - 5));

      expect(await message.future.timeout(const Duration(seconds: 2)), body);

      await sub.cancel();
      unawaited(incoming.close());
      unawaited(outgoing.close());
    });

    test('parses multiple framed messages from one chunk', () async {
      final incoming = StreamController<List<int>>();
      final outgoing = StreamController<List<int>>();
      final channel = streamJsonRpcFramer(incoming.stream, outgoing.sink);
      final messages = <String>[];
      final completer = Completer<List<String>>();
      final sub = channel.stream.listen((msg) {
        messages.add(msg);
        if (messages.length == 2 && !completer.isCompleted) {
          completer.complete(List<String>.from(messages));
        }
      });

      await Future<void>.delayed(Duration.zero);
      incoming.add(_frame('{"a":1}') + _frame('{"b":2}'));

      expect(
        await completer.future.timeout(const Duration(seconds: 2)),
        ['{"a":1}', '{"b":2}'],
      );

      await sub.cancel();
      unawaited(incoming.close());
      unawaited(outgoing.close());
    });

    test('emits format error for missing Content-Length header', () async {
      final incoming = StreamController<List<int>>();
      final outgoing = StreamController<List<int>>();
      final channel = streamJsonRpcFramer(incoming.stream, outgoing.sink);
      final error = Completer<Object>();
      final sub = channel.stream.listen((_) {}, onError: error.complete);

      await Future<void>.delayed(Duration.zero);
      incoming.add(utf8.encode('X-Test: 12\r\n\r\n{"a":1}'));

      expect(await error.future.timeout(const Duration(seconds: 2)),
          isA<FormatException>());

      await sub.cancel();
      unawaited(incoming.close());
      unawaited(outgoing.close());
    });

    test('frames outgoing JSON with Content-Length header', () async {
      final incoming = StreamController<List<int>>();
      final outgoing = StreamController<List<int>>();
      final channel = streamJsonRpcFramer(incoming.stream, outgoing.sink);

      final bytes = <List<int>>[];
      final sub = outgoing.stream.listen(bytes.add);

      channel.sink.add('{"ping":true}');
      await Future<void>.delayed(Duration.zero);

      expect(ascii.decode(bytes.first), 'Content-Length: 13\r\n\r\n');
      expect(utf8.decode(bytes.last), '{"ping":true}');

      await sub.cancel();
      unawaited(incoming.close());
      unawaited(outgoing.close());
    });
  });
}

List<int> _frame(String json) {
  final body = utf8.encode(json);
  return [
    ...ascii.encode('Content-Length: ${body.length}\r\n\r\n'),
    ...body,
  ];
}
