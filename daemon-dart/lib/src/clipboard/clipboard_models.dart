class ClipboardOffer {
  final String offerId;
  final String contentType;
  final int byteSize;
  final String sha256;
  final int expiresInMs;
  final String sourceDeviceId;
  final String requiredCapability;
  final int offerSequence;

  ClipboardOffer({
    required this.offerId,
    required this.contentType,
    required this.byteSize,
    required this.sha256,
    required this.expiresInMs,
    required this.sourceDeviceId,
    required this.requiredCapability,
    required this.offerSequence,
  });

  Map<String, dynamic> toJson() => {
        'offerId': offerId,
        'contentType': contentType,
        'byteSize': byteSize,
        'sha256': sha256,
        'expiresInMs': expiresInMs,
        'sourceDeviceId': sourceDeviceId,
        'requiredCapability': requiredCapability,
        'offerSequence': offerSequence,
      };

  factory ClipboardOffer.fromJson(Map<String, dynamic> json) {
    return ClipboardOffer(
      offerId: json['offerId'] as String,
      contentType: json['contentType'] as String,
      byteSize: json['byteSize'] as int,
      sha256: json['sha256'] as String,
      expiresInMs: json['expiresInMs'] as int,
      sourceDeviceId: json['sourceDeviceId'] as String,
      requiredCapability: json['requiredCapability'] as String,
      offerSequence: json['offerSequence'] as int,
    );
  }
}

class ClipboardFetchRequest {
  final String offerId;
  final String requestingDeviceId;

  ClipboardFetchRequest({
    required this.offerId,
    required this.requestingDeviceId,
  });

  Map<String, dynamic> toJson() => {
        'offerId': offerId,
        'requestingDeviceId': requestingDeviceId,
      };

  factory ClipboardFetchRequest.fromJson(Map<String, dynamic> json) {
    return ClipboardFetchRequest(
      offerId: json['offerId'] as String,
      requestingDeviceId: json['requestingDeviceId'] as String,
    );
  }
}

class ClipboardFetchResponse {
  final String offerId;
  final String contentBase64;
  final int byteSize;
  final String sha256;

  ClipboardFetchResponse({
    required this.offerId,
    required this.contentBase64,
    required this.byteSize,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
        'offerId': offerId,
        'contentBase64': contentBase64,
        'byteSize': byteSize,
        'sha256': sha256,
      };

  factory ClipboardFetchResponse.fromJson(Map<String, dynamic> json) {
    return ClipboardFetchResponse(
      offerId: json['offerId'] as String,
      contentBase64: json['contentBase64'] as String,
      byteSize: json['byteSize'] as int,
      sha256: json['sha256'] as String,
    );
  }
}

class ClipboardFetchReject {
  final String offerId;
  final String failureReason;
  final String? message;

  ClipboardFetchReject({
    required this.offerId,
    required this.failureReason,
    this.message,
  });

  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{
      'offerId': offerId,
      'failureReason': failureReason,
    };
    if (message != null) {
      data['message'] = message;
    }
    return data;
  }

  factory ClipboardFetchReject.fromJson(Map<String, dynamic> json) {
    return ClipboardFetchReject(
      offerId: json['offerId'] as String,
      failureReason: json['failureReason'] as String,
      message: json['message'] as String?,
    );
  }
}
