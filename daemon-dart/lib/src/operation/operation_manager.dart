import 'dart:async';

import '../core/rift_exceptions.dart';
import 'operation_models.dart';

class OperationManager {
  final int retentionLimit;
  final Map<String, OperationRecord> _operationsById = {};
  final List<String> _operationOrder = <String>[];
  final _transitionController =
      StreamController<OperationTransitionEvent>.broadcast();

  OperationManager({this.retentionLimit = 200});

  Stream<OperationTransitionEvent> get onTransition =>
      _transitionController.stream;

  void dispose() {
    _transitionController.close();
  }

  OperationRecord createOperation({
    required String operationId,
    required String operationType,
    required String sourceDeviceId,
    required String destinationDeviceId,
  }) {
    final existing = _operationsById[operationId];
    if (existing != null) {
      return existing;
    }

    final now = DateTime.now().toUtc();
    final record = OperationRecord(
      operationId: operationId,
      operationType: operationType,
      sourceDeviceId: sourceDeviceId,
      destinationDeviceId: destinationDeviceId,
      createdAt: now,
      updatedAt: now,
      state: OperationState.created,
    );
    _operationsById[operationId] = record;
    _operationOrder.add(operationId);
    _pruneIfNeeded();
    return record;
  }

  OperationRecord getOperation(String operationId) {
    final record = _operationsById[operationId];
    if (record == null) {
      throw const RiftNotFoundException('Operation not found');
    }
    return record;
  }

  List<OperationRecord> listOperations({int limit = 50, int offset = 0}) {
    final normalizedOffset = offset < 0 ? 0 : offset;
    final normalizedLimit = limit < 0 ? 0 : limit;
    final reversedIds = _operationOrder.reversed.toList(growable: false);
    return reversedIds
        .skip(normalizedOffset)
        .take(normalizedLimit)
        .map((operationId) => _operationsById[operationId]!)
        .toList(growable: false);
  }

  int get totalCount => _operationsById.length;

  OperationRecord transitionOperation(
    String operationId,
    OperationState nextState, {
    String? failureReason,
    Map<String, dynamic>? details,
  }) {
    final record = getOperation(operationId);
    final previousState = record.state;

    if (previousState.isTerminal) {
      if (previousState == nextState) {
        return record;
      }

      throw RiftInvalidTransitionException(
        'Invalid terminal transition from ${previousState.wireName} to ${nextState.wireName}.',
      );
    }

    if (!_isAllowedTransition(previousState, nextState)) {
      throw RiftInvalidTransitionException(
        'Invalid transition from ${previousState.wireName} to ${nextState.wireName}.',
      );
    }

    final now = DateTime.now().toUtc();
    record.state = nextState;
    record.updatedAt = now;
    if (failureReason != null) {
      record.failureReason = failureReason;
    }
    record.transitions.add(
      OperationTransitionRecord(
        from: previousState,
        to: nextState,
        at: now,
        failureReason: failureReason,
        details: details,
      ),
    );
    try {
      _transitionController.add(
        OperationTransitionEvent(
          operationId: record.operationId,
          operationType: record.operationType,
          previousState: previousState,
          nextState: nextState,
          failureReason: failureReason,
        ),
      );
    } on StateError {
      // Late timers or shutdown can race with disposal; preserve the committed
      // state transition even if no listeners can be notified anymore.
    }
    return record;
  }

  bool _isAllowedTransition(OperationState current, OperationState next) {
    switch (current) {
      case OperationState.created:
        return next == OperationState.pending || next == OperationState.failed;
      case OperationState.pending:
        return next == OperationState.dispatched ||
            next == OperationState.failed ||
            next == OperationState.expired;
      case OperationState.dispatched:
        return next == OperationState.active ||
            next == OperationState.failed ||
            next == OperationState.expired;
      case OperationState.active:
        return next == OperationState.done ||
            next == OperationState.failed ||
            next == OperationState.expired;
      case OperationState.done:
      case OperationState.failed:
      case OperationState.expired:
        return false;
    }
  }

  void _pruneIfNeeded() {
    while (_operationOrder.length > retentionLimit) {
      final removedId = _operationOrder.removeAt(0);
      _operationsById.remove(removedId);
    }
  }
}
