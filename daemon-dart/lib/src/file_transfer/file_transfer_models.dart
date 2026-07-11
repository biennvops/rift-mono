class IncomingFileOfferInfo {
  final String transferId;
  final String sourceDeviceId;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final String sha256;
  final int chunkSize;
  final int chunkCount;
  final String expiresAt;

  const IncomingFileOfferInfo({
    required this.transferId,
    required this.sourceDeviceId,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.sha256,
    required this.chunkSize,
    required this.chunkCount,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'sourceDeviceId': sourceDeviceId,
        'fileName': fileName,
        'mediaType': mediaType,
        'byteSize': byteSize,
        'sha256': sha256,
        'chunkSize': chunkSize,
        'chunkCount': chunkCount,
        'expiresAt': expiresAt,
      };
}

class FileTransferInfo {
  final String transferId;
  final String operationId;
  final String direction;
  final String peerDeviceId;
  final String fileName;
  final String mediaType;
  final int byteSize;
  final int bytesTransferred;
  final String state;
  final String? failureReason;

  const FileTransferInfo({
    required this.transferId,
    required this.operationId,
    required this.direction,
    required this.peerDeviceId,
    required this.fileName,
    required this.mediaType,
    required this.byteSize,
    required this.bytesTransferred,
    required this.state,
    this.failureReason,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'transferId': transferId,
      'operationId': operationId,
      'direction': direction,
      'peerDeviceId': peerDeviceId,
      'fileName': fileName,
      'mediaType': mediaType,
      'byteSize': byteSize,
      'bytesTransferred': bytesTransferred,
      'state': state,
    };
    if (failureReason != null) {
      json['failureReason'] = failureReason;
    }
    return json;
  }
}

class OfferFileResult {
  final String transferId;
  final String operationId;
  final String targetDeviceId;
  final String fileName;
  final int byteSize;
  final int chunkSize;
  final int chunkCount;

  const OfferFileResult({
    required this.transferId,
    required this.operationId,
    required this.targetDeviceId,
    required this.fileName,
    required this.byteSize,
    required this.chunkSize,
    required this.chunkCount,
  });

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'operationId': operationId,
        'targetDeviceId': targetDeviceId,
        'fileName': fileName,
        'byteSize': byteSize,
        'chunkSize': chunkSize,
        'chunkCount': chunkCount,
      };
}

class AcceptFileOfferResult {
  final String transferId;
  final String operationId;
  final String destinationPath;

  const AcceptFileOfferResult({
    required this.transferId,
    required this.operationId,
    required this.destinationPath,
  });

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'operationId': operationId,
        'destinationPath': destinationPath,
      };
}

class RejectFileOfferResult {
  final String transferId;
  final bool rejected;

  const RejectFileOfferResult({
    required this.transferId,
    required this.rejected,
  });

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'rejected': rejected,
      };
}
