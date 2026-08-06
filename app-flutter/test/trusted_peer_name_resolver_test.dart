import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/trusted_peer_name_resolver.dart';

void main() {
  test('returns the matching peer display name', () async {
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async => {
        'peers': [
          {'deviceId': 'device-1', 'displayName': 'Work Laptop'},
        ],
      },
    );

    expect(await resolver.resolve('device-1'), 'Work Laptop');
  });

  test('returns a shortened ID when the peer is unknown', () async {
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async => {'peers': const []},
    );

    expect(await resolver.resolve('device-1234567890'), 'device-12345…');
  });

  test('returns a shortened ID when the display name is missing or empty',
      () async {
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async => {
        'peers': [
          {'deviceId': 'device-missing'},
          {'deviceId': 'device-empty', 'displayName': '  '},
        ],
      },
    );

    expect(await resolver.resolve('device-missing'), 'device-missi…');
    expect(await resolver.resolve('device-empty'), 'device-empty');
  });

  test('returns Trusted device for an empty ID', () async {
    var calls = 0;
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async {
        calls += 1;
        return {'peers': const []};
      },
    );

    expect(await resolver.resolve(''), 'Trusted device');
    expect(calls, 0);
  });

  test('does not throw when peer lookup fails', () async {
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async => throw StateError('offline'),
    );

    expect(await resolver.resolve('device-1234567890'), 'device-12345…');
  });

  test('retries successfully after an earlier refresh failure', () async {
    var calls = 0;
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async {
        calls += 1;
        if (calls == 1) {
          throw StateError('offline');
        }
        return {
          'peers': [
            {'deviceId': 'device-1', 'displayName': 'Phone'},
          ],
        };
      },
    );

    expect(await resolver.resolve('device-1'), 'device-1');
    expect(await resolver.resolve('device-1'), 'Phone');
    expect(calls, 2);
  });

  test('coalesces concurrent cache misses into one refresh', () async {
    final response = Completer<Map<String, dynamic>>();
    var calls = 0;
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () {
        calls += 1;
        return response.future;
      },
    );

    final first = resolver.resolve('device-1');
    final second = resolver.resolve('device-1');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    response.complete({
      'peers': [
        {'deviceId': 'device-1', 'displayName': 'Tablet'},
      ],
    });
    expect(await Future.wait([first, second]), ['Tablet', 'Tablet']);
  });

  test('uses a cached name without another RPC', () async {
    var calls = 0;
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async {
        calls += 1;
        return {
          'peers': [
            {'deviceId': 'device-1', 'displayName': 'Desktop'},
          ],
        };
      },
    );

    expect(await resolver.resolve('device-1'), 'Desktop');
    expect(await resolver.resolve('device-1'), 'Desktop');
    expect(calls, 1);
  });

  test('updates a cached name after a trust-change event', () async {
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async => {
        'peers': [
          {'deviceId': 'device-1', 'displayName': 'Old Name'},
        ],
      },
    );

    expect(await resolver.resolve('device-1'), 'Old Name');
    resolver.applyTrustChanged({
      'deviceId': 'device-1',
      'newState': 'trusted',
      'displayName': 'New Name',
    });

    expect(await resolver.resolve('device-1'), 'New Name');
  });

  test('removes a cached name after revoked trust', () async {
    var calls = 0;
    final resolver = TrustedPeerNameResolver(
      listTrustedPeers: () async {
        calls += 1;
        return calls == 1
            ? {
                'peers': [
                  {'deviceId': 'device-1', 'displayName': 'Old Name'},
                ],
              }
            : {'peers': const []};
      },
    );

    expect(await resolver.resolve('device-1'), 'Old Name');
    resolver.applyTrustChanged({
      'deviceId': 'device-1',
      'newState': 'revoked',
    });

    expect(await resolver.resolve('device-1'), 'device-1');
    expect(calls, 2);
  });
}
