// lib/src/network/session_messages.dart

class Capability {
  final String name;
  final int version;

  Capability({required this.name, required this.version});

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
      };

  factory Capability.fromJson(Map<String, dynamic> json) {
    return Capability(
      name: json['name'] as String,
      version: json['version'] as int,
    );
  }
}

class RiftMessage {
  final String rift;
  final String type;
  final String messageId;
  final String sourceDeviceId;
  final Map<String, dynamic> payload;

  RiftMessage({
    required this.rift,
    required this.type,
    required this.messageId,
    required this.sourceDeviceId,
    required this.payload,
  });

  Map<String, dynamic> toJson() => {
        'rift': rift,
        'type': type,
        'messageId': messageId,
        'sourceDeviceId': sourceDeviceId,
        'payload': payload,
      };

  factory RiftMessage.fromJson(Map<String, dynamic> json) {
    return RiftMessage(
      rift: json['rift'] as String,
      type: json['type'] as String,
      messageId: json['messageId'] as String,
      sourceDeviceId: json['sourceDeviceId'] as String,
      payload: json['payload'] as Map<String, dynamic>,
    );
  }
}

class SessionHelloPayload {
  final List<String> supportedVersions;
  final String deviceId;
  final String implementationId;
  final List<Capability> capabilities;

  SessionHelloPayload({
    required this.supportedVersions,
    required this.deviceId,
    required this.implementationId,
    required this.capabilities,
  });

  Map<String, dynamic> toJson() => {
        'supportedVersions': supportedVersions,
        'deviceId': deviceId,
        'implementationId': implementationId,
        'capabilities': capabilities.map((c) => c.toJson()).toList(),
      };

  factory SessionHelloPayload.fromJson(Map<String, dynamic> json) {
    return SessionHelloPayload(
      supportedVersions: List<String>.from(json['supportedVersions']),
      deviceId: json['deviceId'] as String,
      implementationId: json['implementationId'] as String,
      capabilities: (json['capabilities'] as List)
          .map((c) => Capability.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SessionAcceptPayload {
  final String selectedVersion;
  final String deviceId;
  final bool identityVerified;
  final List<Capability> capabilities;

  SessionAcceptPayload({
    required this.selectedVersion,
    required this.deviceId,
    required this.identityVerified,
    required this.capabilities,
  });

  Map<String, dynamic> toJson() => {
        'selectedVersion': selectedVersion,
        'deviceId': deviceId,
        'identityVerified': identityVerified,
        'capabilities': capabilities.map((c) => c.toJson()).toList(),
      };

  factory SessionAcceptPayload.fromJson(Map<String, dynamic> json) {
    return SessionAcceptPayload(
      selectedVersion: json['selectedVersion'] as String,
      deviceId: json['deviceId'] as String,
      identityVerified: json['identityVerified'] as bool,
      capabilities: (json['capabilities'] as List)
          .map((c) => Capability.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SessionRejectPayload {
  final String failureReason;
  final String? message;

  SessionRejectPayload({
    required this.failureReason,
    this.message,
  });

  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{
      'failureReason': failureReason,
    };
    if (message != null) {
      data['message'] = message;
    }
    return data;
  }

  factory SessionRejectPayload.fromJson(Map<String, dynamic> json) {
    return SessionRejectPayload(
      failureReason: json['failureReason'] as String,
      message: json['message'] as String?,
    );
  }
}
