import 'dart:convert';

/// Standard kernel syscall error codes ([D-004]).
enum SyscallErrorCode {
  einval('EINVAL'),
  enoent('ENOENT'),
  eexist('EEXIST'),
  econflict('ECONFLICT'),
  eacces('EACCES'),
  eperm('EPERM'),
  etimedout('ETIMEDOUT'),
  ecancelled('ECANCELLED'),
  edquot('EDQUOT'),
  eprovider('EPROVIDER'),
  eio('EIO');

  const SyscallErrorCode(this.codeName);

  /// Uppercase POSIX-like error code string used in logs and JSON payloads.
  final String codeName;
}

/// Structured syscall error returned to callers and serialized for LLM recovery ([D-004]).
class SyscallError {
  const SyscallError({
    required this.code,
    required this.reason,
    required this.message,
    this.recoverable = false,
    this.hint,
    this.details,
  });

  final SyscallErrorCode code;
  final String reason;
  final String message;
  final bool recoverable;
  final String? hint;
  final Map<String, dynamic>? details;

  /// Converts this error into a JSON-serializable map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code.codeName,
      'reason': reason,
      'message': message,
      'recoverable': recoverable,
      if (hint != null) 'hint': hint,
      if (details != null) 'details': details,
    };
  }

  /// Serializes this error as a JSON string for LLM Tool Result payloads.
  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() => 'SyscallError(${code.codeName}, $reason: $message)';
}

/// Result envelope returned by every syscall invocation without leaking uncaught exceptions ([D-004]).
class SyscallResult<T> {
  const SyscallResult._({
    required this.ok,
    this.value,
    this.error,
  });

  /// Constructs a successful syscall result.
  const SyscallResult.success(T value)
      : this._(ok: true, value: value, error: null);

  /// Constructs a failed syscall result.
  const SyscallResult.failure(SyscallError error)
      : this._(ok: false, value: null, error: error);

  final bool ok;
  final T? value;
  final SyscallError? error;

  bool get isSuccess => ok;
  bool get isFailure => !ok;

  /// Pattern-matches on success or failure.
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(SyscallError error) onFailure,
  ) {
    if (ok) {
      return onSuccess(value as T);
    }
    return onFailure(error!);
  }
}
