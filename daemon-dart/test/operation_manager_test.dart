import 'dart:async';

import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/operation/operation_manager.dart';
import 'package:daemon_dart/src/operation/operation_models.dart';
import 'package:test/test.dart';

void main() {
  group('OperationManager', () {
    late OperationManager manager;

    setUp(() {
      manager = OperationManager(retentionLimit: 10);
    });

    tearDown(() {
      manager.dispose();
    });

    test('accepts valid lifecycle transitions', () {
      final operation = manager.createOperation(
        operationId: 'op-1',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );

      expect(operation.state, OperationState.created);

      manager.transitionOperation('op-1', OperationState.pending);
      manager.transitionOperation('op-1', OperationState.dispatched);
      manager.transitionOperation('op-1', OperationState.active);
      final completed = manager.transitionOperation('op-1', OperationState.done);

      expect(completed.state, OperationState.done);
      expect(completed.transitions.length, 4);
    });

    test('rejects out of order transitions', () {
      manager.createOperation(
        operationId: 'op-2',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );

      expect(
        () => manager.transitionOperation('op-2', OperationState.active),
        throwsA(isA<RiftInvalidTransitionException>()),
      );
    });

    test('treats duplicate terminal transitions as idempotent', () {
      manager.createOperation(
        operationId: 'op-3',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );

      manager.transitionOperation('op-3', OperationState.pending);
      manager.transitionOperation('op-3', OperationState.dispatched);
      manager.transitionOperation('op-3', OperationState.active);
      final failed = manager.transitionOperation(
        'op-3',
        OperationState.failed,
        failureReason: 'PeerUnreachable',
      );
      final duplicate = manager.transitionOperation(
        'op-3',
        OperationState.failed,
        failureReason: 'PeerUnreachable',
      );

      expect(identical(failed, duplicate), isTrue);
      expect(duplicate.transitions.length, 4);
    });

    test('rejects conflicting terminal transitions', () {
      manager.createOperation(
        operationId: 'op-4',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );

      manager.transitionOperation('op-4', OperationState.pending);
      manager.transitionOperation('op-4', OperationState.dispatched);
      manager.transitionOperation(
        'op-4',
        OperationState.expired,
        failureReason: 'Timeout',
      );

      expect(
        () => manager.transitionOperation('op-4', OperationState.done),
        throwsA(isA<RiftInvalidTransitionException>()),
      );
    });

    test('accepts created to failed shortcut', () {
      manager.createOperation(
        operationId: 'op-created-failed',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );

      final failed = manager.transitionOperation(
        'op-created-failed',
        OperationState.failed,
        failureReason: 'PeerUnreachable',
      );
      final duplicate = manager.transitionOperation(
        'op-created-failed',
        OperationState.failed,
        failureReason: 'PeerUnreachable',
      );

      expect(failed.state, OperationState.failed);
      expect(failed.failureReason, 'PeerUnreachable');
      expect(failed.transitions.length, 1);
      expect(identical(failed, duplicate), isTrue);
    });

    test('prunes oldest operations when retention limit is exceeded', () {
      final pruningManager = OperationManager(retentionLimit: 2);
      addTearDown(pruningManager.dispose);

      pruningManager.createOperation(
        operationId: 'op-oldest',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-a',
      );
      pruningManager.transitionOperation(
        'op-oldest',
        OperationState.failed,
        failureReason: 'PeerUnreachable',
      );
      pruningManager.createOperation(
        operationId: 'op-middle',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-b',
      );
      pruningManager.createOperation(
        operationId: 'op-newest',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-c',
      );

      expect(pruningManager.totalCount, 2);
      expect(
        () => pruningManager.getOperation('op-oldest'),
        throwsA(isA<RiftNotFoundException>()),
      );

      final listed = pruningManager.listOperations(limit: 10);
      expect(listed.map((operation) => operation.operationId), [
        'op-newest',
        'op-middle',
      ]);
      expect(pruningManager.getOperation('op-middle').operationId, 'op-middle');
      expect(pruningManager.getOperation('op-newest').operationId, 'op-newest');
    });

    test('does not prune in-flight operations when retention limit is exceeded',
        () {
      final pruningManager = OperationManager(retentionLimit: 2);
      addTearDown(pruningManager.dispose);

      pruningManager.createOperation(
        operationId: 'op-oldest',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-a',
      );
      pruningManager.transitionOperation('op-oldest', OperationState.pending);
      pruningManager.createOperation(
        operationId: 'op-middle',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-b',
      );
      pruningManager.createOperation(
        operationId: 'op-newest',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer-c',
      );

      expect(pruningManager.totalCount, 3);
      expect(pruningManager.getOperation('op-oldest').operationId, 'op-oldest');
      expect(pruningManager.getOperation('op-middle').operationId, 'op-middle');
      expect(pruningManager.getOperation('op-newest').operationId, 'op-newest');
    });

    test('listener exceptions do not roll back successful transitions', () async {
      final asyncErrors = <Object>[];

      await runZonedGuarded(() async {
        manager.onTransition.listen((event) {
          if (event.nextState == OperationState.done) {
            throw StateError('listener boom');
          }
        });

        manager.createOperation(
          operationId: 'op-5',
          operationType: 'clipboard.fetch',
          sourceDeviceId: 'rift-local',
          destinationDeviceId: 'rift-peer',
        );

        manager.transitionOperation('op-5', OperationState.pending);
        manager.transitionOperation('op-5', OperationState.dispatched);
        manager.transitionOperation('op-5', OperationState.active);
        final completed = manager.transitionOperation(
          'op-5',
          OperationState.done,
        );

        expect(completed.state, OperationState.done);

        // Broadcast delivery is asynchronous; give the zone a turn to observe
        // any uncaught listener failure.
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) {
        asyncErrors.add(error);
      });

      expect(asyncErrors, isNotEmpty);
      expect(asyncErrors.single, isA<StateError>());
      expect(manager.getOperation('op-5').state, OperationState.done);
    });

    test('duplicate done transition remains idempotent even after listener failure',
        () async {
      final asyncErrors = <Object>[];

      await runZonedGuarded(() async {
        manager.onTransition.listen((event) {
          if (event.nextState == OperationState.done) {
            throw StateError('listener boom');
          }
        });

        manager.createOperation(
          operationId: 'op-6',
          operationType: 'clipboard.fetch',
          sourceDeviceId: 'rift-local',
          destinationDeviceId: 'rift-peer',
        );

        manager.transitionOperation('op-6', OperationState.pending);
        manager.transitionOperation('op-6', OperationState.dispatched);
        manager.transitionOperation('op-6', OperationState.active);
        manager.transitionOperation('op-6', OperationState.done);

        await Future<void>.delayed(Duration.zero);

        final duplicate = manager.transitionOperation(
          'op-6',
          OperationState.done,
        );
        expect(duplicate.state, OperationState.done);
        expect(duplicate.transitions.length, 4);
      }, (error, stackTrace) {
        asyncErrors.add(error);
      });

      expect(asyncErrors, isNotEmpty);
      expect(manager.getOperation('op-6').state, OperationState.done);
    });

    test('transition after dispose preserves committed state without throwing', () {
      manager.createOperation(
        operationId: 'op-7',
        operationType: 'clipboard.fetch',
        sourceDeviceId: 'rift-local',
        destinationDeviceId: 'rift-peer',
      );
      manager.transitionOperation('op-7', OperationState.pending);
      manager.dispose();

      final transitioned = manager.transitionOperation(
        'op-7',
        OperationState.dispatched,
      );

      expect(transitioned.state, OperationState.dispatched);
      expect(transitioned.transitions.length, 2);
    });
  });
}
