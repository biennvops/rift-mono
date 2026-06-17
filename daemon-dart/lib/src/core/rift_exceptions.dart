class RiftException implements Exception {
  final int code;
  final String message;

  const RiftException(this.code, this.message);

  @override
  String toString() => 'RiftException($code): $message';
}

class RiftNotFoundException extends RiftException {
  const RiftNotFoundException(String message) : super(-32009, message);
}

class RiftUnauthorizedException extends RiftException {
  const RiftUnauthorizedException(String message) : super(-32004, message);
}

class RiftAuthenticationFailedException extends RiftException {
  const RiftAuthenticationFailedException(String message) : super(-32005, message);
}

class RiftInvalidTransitionException extends RiftException {
  const RiftInvalidTransitionException(String message) : super(-32008, message);
}

class RiftIdentityNotInitializedException extends RiftException {
  const RiftIdentityNotInitializedException(String message) : super(-32012, message);
}
