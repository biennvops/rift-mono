enum OperationState {
  created('Created'),
  pending('Pending'),
  dispatched('Dispatched'),
  active('Active'),
  done('Done'),
  failed('Failed'),
  expired('Expired');

  const OperationState(this.wireName);

  final String wireName;

  bool get isTerminal =>
      this == OperationState.done ||
      this == OperationState.failed ||
      this == OperationState.expired;
}

class OperationTransitionRecord {
  final OperationState from;
  final OperationState to;
  final DateTime at;
  final String? failureReason;
  final Map<String, dynamic>? details;

  const OperationTransitionRecord({
    required this.from,
    required this.to,
    required this.at,
    this.failureReason,
    this.details,
  });

  Map<String, dynamic> toJson() {
    return {
      'from': from.wireName,
      'to': to.wireName,
      'at': at.toUtc().toIso8601String(),
      if (failureReason != null) 'failureReason': failureReason,
      if (details != null) 'details': details,
    };
  }
}

class OperationRecord {
  final String operationId;
  final String operationType;
  final String sourceDeviceId;
  final String destinationDeviceId;
  final DateTime createdAt;
  DateTime updatedAt;
  OperationState state;
  String? failureReason;
  final List<OperationTransitionRecord> transitions;

  OperationRecord({
    required this.operationId,
    required this.operationType,
    required this.sourceDeviceId,
    required this.destinationDeviceId,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    this.failureReason,
    List<OperationTransitionRecord>? transitions,
  }) : transitions = transitions ?? <OperationTransitionRecord>[];

  Map<String, dynamic> toListJson() {
    return {
      'operationId': operationId,
      'operationType': operationType,
      'state': state.wireName,
      'sourceDeviceId': sourceDeviceId,
      'destinationDeviceId': destinationDeviceId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> toDetailJson() {
    return {
      ...toListJson(),
      'transitions': transitions.map((transition) => transition.toJson()).toList(),
      if (failureReason != null) 'failureReason': failureReason,
    };
  }
}

class OperationTransitionEvent {
  final String operationId;
  final String operationType;
  final OperationState previousState;
  final OperationState nextState;
  final String? failureReason;

  const OperationTransitionEvent({
    required this.operationId,
    required this.operationType,
    required this.previousState,
    required this.nextState,
    this.failureReason,
  });

  Map<String, dynamic> toJson() {
    return {
      'operationId': operationId,
      'operationType': operationType,
      'previousState': previousState.wireName,
      'nextState': nextState.wireName,
      if (failureReason != null) 'failureReason': failureReason,
    };
  }
}
