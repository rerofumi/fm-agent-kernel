import 'dart:async';

/// Cooperative cancellation token passed through syscalls, drivers, and approval waits.
class CancellationToken {
  CancellationToken._();

  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;
  String? _reason;

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// Optional reason supplied when cancelled.
  String? get reason => _reason;

  /// Future that completes when [cancel] is triggered.
  Future<void> get onCancel => _completer.future;

  void _trigger([String? reason]) {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _reason = reason;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Controller that creates and cancels a [CancellationToken].
class CancellationTokenSource {
  final CancellationToken token = CancellationToken._();

  /// Requests cancellation of all operations observing [token].
  void cancel([String? reason]) {
    token._trigger(reason);
  }
}
