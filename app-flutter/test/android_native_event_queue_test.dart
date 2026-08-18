import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rift/src/ipc/android_native_event_queue.dart';

Map<String, dynamic> notificationEvent(
  String eventType,
  String notificationId, {
  int? revision,
  String? title,
}) {
  return <String, dynamic>{
    'eventType': eventType,
    'notificationId': notificationId,
    if (revision != null) 'revision': revision,
    if (title != null) 'title': title,
  };
}

Map<String, dynamic> mediaEvent(
  String eventType,
  String playbackId, {
  int? revision,
  Map<String, dynamic>? artwork,
  bool artworkPending = false,
}) {
  return <String, dynamic>{
    'eventType': eventType,
    'playbackId': playbackId,
    if (revision != null) 'revision': revision,
    if (artwork != null) 'artwork': artwork,
    if (artworkPending) 'artworkPending': true,
  };
}

Map<String, dynamic> mediaAction(
  String action, {
  String sourceDeviceId = 'device-1',
  String playbackId = 'playback-1',
  int? positionMs,
}) {
  return <String, dynamic>{
    'eventType': 'mediaPlaybackAction',
    'sourceDeviceId': sourceDeviceId,
    'playbackId': playbackId,
    'action': action,
    if (positionMs != null) 'positionMs': positionMs,
  };
}

Future<AndroidNativeEventDispatchResult> deliver(
  AndroidNativeEvent event,
) async {
  return AndroidNativeEventDispatchResult.delivered;
}

void main() {
  group('validation and dispatch failures', () {
    test('dispatcher exception cannot poison later work', () async {
      final deliveredIds = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          if (event.entityKey == 'poison') {
            throw const FormatException('permanent failure');
          }
          deliveredIds.add(event.entityKey);
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'poison'));
      queue.enqueue(mediaEvent('updated', 'healthy'));
      await queue.flush();

      expect(deliveredIds, <String>['healthy']);
      expect(queue, isEmpty);
    });

    test('malformed events are rejected before enqueue', () async {
      final logs = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: deliver,
        logger: logs.add,
      )..onConnected();
      final invalidEvents = <Map<String, dynamic>>[
        <String, dynamic>{'playbackId': 'playback-1'},
        mediaEvent('updated', ' '),
        <String, dynamic>{
          'eventType': 'updated',
          'notificationId': 'notification-1',
          'playbackId': 'playback-1',
        },
        <String, dynamic>{
          'eventType': 'unknown',
          'playbackId': 'playback-1',
        },
        mediaAction('dismiss'),
        mediaAction('seek'),
        <String, dynamic>{
          ...mediaAction('seek'),
          'positionMs': 1.5,
        },
      ];

      for (final event in invalidEvents) {
        expect(queue.enqueue(event), isFalse);
      }
      expect(queue, isEmpty);

      expect(queue.enqueue(mediaEvent('updated', 'healthy')), isTrue);
      await queue.flush();

      expect(queue, isEmpty);
      expect(
        logs.where((message) => message.contains('invalid native event')),
        hasLength(invalidEvents.length),
      );
    });

    test('permanent RPC rejection drops only the rejected event', () async {
      final dispatched = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatched.add(event.entityKey);
          return event.entityKey == 'rejected'
              ? AndroidNativeEventDispatchResult.drop
              : AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'rejected'));
      queue.enqueue(mediaEvent('updated', 'accepted'));
      await queue.flush();

      expect(dispatched, <String>['rejected', 'accepted']);
      expect(queue, isEmpty);
    });
  });

  group('connection generations and ephemeral commands', () {
    test('retryable disconnected state survives reconnect', () async {
      final deliveredIds = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          deliveredIds.add(event.entityKey);
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-1'));
      queue.onConnectionLost();
      await queue.flush();

      expect(queue.length, 1);
      expect(deliveredIds, isEmpty);

      queue.onConnected();
      await queue.flush();

      expect(deliveredIds, <String>['playback-1']);
      expect(queue, isEmpty);
    });

    test('disconnected media command is never retained or replayed', () async {
      final dispatched = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatched.add(event.payload['action'] as String);
          return AndroidNativeEventDispatchResult.delivered;
        },
      );

      expect(queue.enqueue(mediaAction('pause')), isFalse);
      expect(queue, isEmpty);

      queue.onConnected();
      await queue.flush();

      expect(dispatched, isEmpty);
    });

    test('command interrupted by disconnect is not retried', () async {
      final dispatchStarted = Completer<void>();
      final dispatchResult = Completer<AndroidNativeEventDispatchResult>();
      var dispatchCount = 0;
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatchCount += 1;
          dispatchStarted.complete();
          return dispatchResult.future;
        },
      )..onConnected();

      queue.enqueue(mediaAction('next'));
      final flush = queue.flush();
      await dispatchStarted.future;
      queue.onConnectionLost();
      dispatchResult.complete(AndroidNativeEventDispatchResult.retryLater);
      await flush;

      queue.onConnected();
      await queue.flush();

      expect(dispatchCount, 1);
      expect(queue, isEmpty);
    });

    test('disconnect invalidates commands from the old generation', () async {
      var dispatchCount = 0;
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatchCount += 1;
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();
      final firstGeneration = queue.connectionGeneration;

      queue.enqueue(mediaAction('pause'));
      expect(queue.queuedEvents.single.connectionGeneration, firstGeneration);
      queue.onConnectionLost();
      final secondGeneration = queue.connectionGeneration;
      queue.onConnected();
      await queue.flush();

      expect(secondGeneration, greaterThan(firstGeneration));
      expect(queue.connectionGeneration, secondGeneration);
      expect(dispatchCount, 0);
      expect(queue, isEmpty);
    });
  });

  group('policy gating and state coalescing', () {
    test('notification policy does not block media state', () async {
      final dispatched = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatched.add('${event.kind.name}:${event.entityKey}');
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(notificationEvent('posted', 'notification-1'));
      queue.enqueue(mediaEvent('updated', 'playback-1'));
      await queue.flush();

      expect(
        dispatched,
        <String>['mediaPlaybackState:playback-1'],
      );
      expect(queue.length, 1);
      expect(queue.queuedEvents.single.entityKey, 'notification-1');

      queue.setNotificationPolicyReady(true);
      await queue.flush();

      expect(
        dispatched,
        <String>[
          'mediaPlaybackState:playback-1',
          'notificationState:notification-1',
        ],
      );
      expect(queue, isEmpty);
    });

    test('policy-blocked notification cannot be resurrected', () async {
      final eventTypes = <String>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          eventTypes.add(event.eventType);
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(notificationEvent('posted', 'notification-1'));
      queue.enqueue(notificationEvent('removed', 'notification-1'));

      expect(queue.length, 1);
      expect(queue.queuedEvents.single.eventType, 'removed');
      await queue.flush();
      queue.setNotificationPolicyReady(true);
      await queue.flush();

      expect(eventTypes, <String>['removed']);
      expect(queue, isEmpty);
    });

    test('notification post and updates coalesce to newest posted state', () {
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      queue.enqueue(
        notificationEvent('posted', 'notification-1', revision: 1),
      );
      queue.enqueue(
        notificationEvent('updated', 'notification-1', revision: 2),
      );
      queue.enqueue(
        notificationEvent('updated', 'notification-1', revision: 3),
      );

      expect(queue.length, 1);
      final event = queue.queuedEvents.single;
      expect(event.eventType, 'posted');
      expect(event.payload['eventType'], 'posted');
      expect(event.payload['revision'], 3);
    });

    test('media artwork survives posted and updated coalescing', () {
      const artworkA = <String, dynamic>{
        'mediaType': 'image/png',
        'dataBase64': 'AAAA',
        'byteSize': 3,
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
      const artworkB = <String, dynamic>{
        'mediaType': 'image/png',
        'dataBase64': 'BBBB',
        'byteSize': 3,
        'sha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      };
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      queue.enqueue(
        mediaEvent('posted', 'android-session', artwork: artworkA),
      );
      queue.enqueue(
        mediaEvent('updated', 'android-session', artwork: artworkB),
      );

      expect(queue.length, 1);
      final event = queue.queuedEvents.single;
      expect(event.eventType, 'posted');
      expect(event.payload['artwork'], artworkB);
      expect(event.payload.containsKey('artworkPending'), isFalse);
    });

    test('pending artwork coalesces to the later encoded artwork', () async {
      const artwork = <String, dynamic>{
        'mediaType': 'image/png',
        'dataBase64': 'AAAA',
        'byteSize': 3,
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
      final dispatched = <Map<String, dynamic>>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatched.add(event.payload);
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(
        mediaEvent('updated', 'android-session', artworkPending: true),
      );
      queue.enqueue(
        mediaEvent('updated', 'android-session', artwork: artwork),
      );

      expect(queue.length, 1);
      expect(queue.queuedEvents.single.payload['artwork'], artwork);
      expect(queue.queuedEvents.single.payload.containsKey('artworkPending'),
          isFalse);
      await queue.flush();

      expect(dispatched, hasLength(1));
      expect(dispatched.single['artwork'], artwork);
    });

    test('final encoded artwork is not lost after a pending replacement', () {
      const artworkA = <String, dynamic>{
        'mediaType': 'image/png',
        'dataBase64': 'AAAA',
        'byteSize': 3,
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
      const artworkB = <String, dynamic>{
        'mediaType': 'image/png',
        'dataBase64': 'BBBB',
        'byteSize': 3,
        'sha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      };
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      queue.enqueue(
        mediaEvent('updated', 'android-session', artwork: artworkA),
      );
      queue.enqueue(
        mediaEvent('updated', 'android-session', artworkPending: true),
      );
      expect(queue.queuedEvents.single.payload['artworkPending'], isTrue);

      queue.enqueue(
        mediaEvent('updated', 'android-session', artwork: artworkB),
      );

      final event = queue.queuedEvents.single;
      expect(event.payload['artwork'], artworkB);
      expect(event.payload.containsKey('artworkPending'), isFalse);
    });

    test('one hundred media updates coalesce to the latest state', () {
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      for (var revision = 0; revision < 100; revision += 1) {
        queue.enqueue(
          mediaEvent('updated', 'playback-1', revision: revision),
        );
      }

      expect(queue.length, 1);
      expect(queue.queuedEvents.single.payload['revision'], 99);
    });

    test('removals supersede stale media and notification updates', () {
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      queue.enqueue(mediaEvent('updated', 'playback-1'));
      queue.enqueue(mediaEvent('removed', 'playback-1'));
      queue.enqueue(notificationEvent('updated', 'notification-1'));
      queue.enqueue(notificationEvent('removed', 'notification-1'));

      expect(queue.length, 2);
      expect(
        queue.queuedEvents.map((event) => event.eventType),
        everyElement('removed'),
      );
    });

    test('state for independent entities remains independently queued', () {
      final queue = AndroidNativeEventQueue(dispatch: deliver);

      queue.enqueue(mediaEvent('updated', 'playback-a', revision: 1));
      queue.enqueue(mediaEvent('updated', 'playback-b', revision: 1));
      queue.enqueue(
        notificationEvent('updated', 'notification-c', revision: 1),
      );
      queue.enqueue(mediaEvent('updated', 'playback-a', revision: 2));

      expect(queue.length, 3);
      expect(
        queue.queuedEvents.map((event) => event.entityKey),
        <String>['playback-a', 'playback-b', 'notification-c'],
      );
      expect(queue.queuedEvents.first.payload['revision'], 2);
    });

    test('new state arriving during dispatch is not removed with old state',
        () async {
      final firstDispatchStarted = Completer<void>();
      final releaseFirstDispatch = Completer<void>();
      final revisions = <int>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          final revision = event.payload['revision'] as int;
          revisions.add(revision);
          if (revision == 1) {
            firstDispatchStarted.complete();
            await releaseFirstDispatch.future;
          }
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-1', revision: 1));
      final flush = queue.flush();
      await firstDispatchStarted.future;
      queue.enqueue(mediaEvent('updated', 'playback-1', revision: 2));
      releaseFirstDispatch.complete();
      await flush;

      expect(revisions, <int>[1, 2]);
      expect(queue, isEmpty);
    });
  });

  group('bounded queue and retries', () {
    test('queue never exceeds capacity and evicts oldest active state', () {
      final queue = AndroidNativeEventQueue(
        dispatch: deliver,
        capacity: 3,
      );

      for (var index = 0; index < 5; index += 1) {
        queue.enqueue(mediaEvent('updated', 'playback-$index'));
        expect(queue.length, lessThanOrEqualTo(3));
      }

      expect(
        queue.queuedEvents.map((event) => event.entityKey),
        <String>['playback-2', 'playback-3', 'playback-4'],
      );
    });

    test('removals are retained ahead of supersedable state', () {
      final queue = AndroidNativeEventQueue(
        dispatch: deliver,
        capacity: 3,
      );

      queue.enqueue(mediaEvent('updated', 'playback-a'));
      queue.enqueue(mediaEvent('updated', 'playback-b'));
      queue.enqueue(mediaEvent('updated', 'playback-c'));
      queue.enqueue(mediaEvent('removed', 'playback-d'));
      queue.enqueue(mediaEvent('updated', 'playback-e'));

      expect(queue.length, 3);
      expect(
        queue.queuedEvents.map((event) => event.entityKey),
        <String>['playback-c', 'playback-d', 'playback-e'],
      );
      expect(
        queue.queuedEvents
            .singleWhere(
              (event) => event.entityKey == 'playback-d',
            )
            .isRemoval,
        isTrue,
      );
    });

    test('command is dropped when the queue is overloaded', () {
      final queue = AndroidNativeEventQueue(
        dispatch: deliver,
        capacity: 1,
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-1'));

      expect(queue.enqueue(mediaAction('pause')), isFalse);
      expect(queue.length, 1);
      expect(queue.queuedEvents.single.isState, isTrue);
    });

    test('retry budget is bounded and later events continue', () async {
      final dispatchCounts = <String, int>{};
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          dispatchCounts.update(
            event.entityKey,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          return event.entityKey == 'retrying'
              ? AndroidNativeEventDispatchResult.retryLater
              : AndroidNativeEventDispatchResult.delivered;
        },
        maxStateDispatchAttempts: 3,
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'retrying'));
      queue.enqueue(mediaEvent('updated', 'healthy'));
      await queue.flush();

      expect(dispatchCounts['retrying'], 1);
      expect(dispatchCounts['healthy'], 1);
      expect(queue.length, 1);

      await queue.flush();
      await queue.flush();

      expect(dispatchCounts['retrying'], 3);
      expect(queue, isEmpty);
    });

    test('newer state resets retry metadata', () async {
      final revisions = <int>[];
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          final revision = event.payload['revision'] as int;
          revisions.add(revision);
          return revision == 1
              ? AndroidNativeEventDispatchResult.retryLater
              : AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-1', revision: 1));
      await queue.flush();
      expect(queue.queuedEvents.single.dispatchAttempts, 1);

      queue.enqueue(mediaEvent('updated', 'playback-1', revision: 2));
      expect(queue.queuedEvents.single.dispatchAttempts, 0);
      await queue.flush();

      expect(revisions, <int>[1, 2]);
      expect(queue, isEmpty);
    });
  });

  group('single-flight draining', () {
    test('concurrent flushes use one dispatcher drain', () async {
      final firstDispatchStarted = Completer<void>();
      final releaseFirstDispatch = Completer<void>();
      final order = <String>[];
      var activeDispatches = 0;
      var maximumActiveDispatches = 0;
      final queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          activeDispatches += 1;
          if (activeDispatches > maximumActiveDispatches) {
            maximumActiveDispatches = activeDispatches;
          }
          order.add(event.entityKey);
          if (event.entityKey == 'playback-a') {
            firstDispatchStarted.complete();
            await releaseFirstDispatch.future;
          }
          activeDispatches -= 1;
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-a'));
      final firstFlush = queue.flush();
      await firstDispatchStarted.future;
      queue.enqueue(mediaEvent('updated', 'playback-b'));
      final secondFlush = queue.flush();
      releaseFirstDispatch.complete();
      await Future.wait(<Future<void>>[firstFlush, secondFlush]);

      expect(maximumActiveDispatches, 1);
      expect(order, <String>['playback-a', 'playback-b']);
      expect(queue, isEmpty);
    });

    test('enqueue during a drain has no lost wake-up', () async {
      late AndroidNativeEventQueue queue;
      final order = <String>[];
      queue = AndroidNativeEventQueue(
        dispatch: (event) async {
          order.add(event.entityKey);
          if (event.entityKey == 'playback-a') {
            queue.enqueue(mediaEvent('updated', 'playback-b'));
          }
          return AndroidNativeEventDispatchResult.delivered;
        },
      )..onConnected();

      queue.enqueue(mediaEvent('updated', 'playback-a'));
      await queue.flush();

      expect(order, <String>['playback-a', 'playback-b']);
      expect(queue, isEmpty);
    });
  });

  test('dispose waits for an active dispatch', () async {
    final dispatchStarted = Completer<void>();
    final dispatchGate = Completer<void>();
    final queue = AndroidNativeEventQueue(
      dispatch: (event) async {
        dispatchStarted.complete();
        await dispatchGate.future;
        return AndroidNativeEventDispatchResult.delivered;
      },
    )..onConnected();
    queue.enqueue(mediaEvent('updated', 'playback-1'));
    final flush = queue.flush();
    await dispatchStarted.future;
    var disposeComplete = false;
    final dispose = queue.dispose().then((_) {
      disposeComplete = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(disposeComplete, isFalse);

    dispatchGate.complete();
    await Future.wait<void>([flush, dispose]);
    expect(disposeComplete, isTrue);
  });

  test('dispose drops queued work and rejects later native events', () async {
    var dispatches = 0;
    final queue = AndroidNativeEventQueue(
      dispatch: (event) async {
        dispatches += 1;
        return AndroidNativeEventDispatchResult.delivered;
      },
    )..onConnected();
    queue.setNotificationPolicyReady(false);
    queue.enqueue(notificationEvent('posted', 'notification-1'));
    queue.enqueue(mediaAction('play', playbackId: 'playback-1'));

    await queue.dispose();
    await queue.dispose();

    expect(queue.isDisposed, isTrue);
    expect(queue, isEmpty);
    expect(
      queue.enqueue(mediaAction('pause', playbackId: 'playback-2')),
      isFalse,
    );
    queue.onConnected();
    await queue.flush();
    expect(queue.isConnected, isFalse);
    expect(dispatches, 0);
  });

  test('diagnostics do not include notification content', () {
    final logs = <String>[];
    final queue = AndroidNativeEventQueue(
      dispatch: deliver,
      logger: logs.add,
    );

    queue.enqueue(
      notificationEvent(
        'posted',
        'notification-1',
        title: 'private notification title',
      ),
    );

    expect(logs.join('\n'), isNot(contains('private notification title')));
    expect(logs.join('\n'), contains('notificationId=notification-1'));
  });
}
