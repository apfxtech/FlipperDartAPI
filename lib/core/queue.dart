part of '../flipper_client.dart';

/// One outbound RPC frame waiting for its turn on the transport.
///
/// Settles exactly once: [markSent] when the frame was handed to the
/// transport, or [fail] when it never made it out.
class _QueuedRequest implements Comparable<_QueuedRequest> {
  final Main frame;
  final FlipperRequestPriority priority;
  final int seq;
  final void Function()? onSent;
  final void Function(Object error)? onError;
  bool _settled = false;

  _QueuedRequest({
    required this.frame,
    required this.priority,
    required this.seq,
    this.onSent,
    this.onError,
  });

  void markSent() {
    if (_settled) return;
    _settled = true;
    onSent?.call();
  }

  void fail(Object error) {
    if (_settled) return;
    _settled = true;
    onError?.call(error);
  }

  @override
  int compareTo(_QueuedRequest other) {
    final byPriority = priority.index.compareTo(other.priority.index);
    if (byPriority != 0) return byPriority;
    return seq.compareTo(other.seq);
  }
}

/// In-flight RPC call: collects response frames and owns the response
/// watchdog timer. Completes exactly once.
class _PendingRpc {
  final int commandId;
  final List<Main> frames = [];
  final Completer<List<Main>> _completer = Completer<List<Main>>();
  final Completer<void> _settled = Completer<void>();
  Timer? _timeoutTimer;
  Duration? _watchdogTimeout;
  void Function()? _watchdogCallback;

  _PendingRpc(this.commandId);

  void Function(Main frame)? onFrame;

  Future<List<Main>> get future => _completer.future;

  /// Resolves when the call settles — success or failure — and never errors.
  /// Lets the TX worker wait for the response without try/catch.
  Future<void> get settled => _settled.future;

  bool get isDone => _completer.isCompleted;

  void add(Main frame) {
    frames.add(frame);
    onFrame?.call(frame);
  }

  void armTimeout(Duration timeout, void Function() onTimeout) {
    _watchdogTimeout = timeout;
    _watchdogCallback = onTimeout;
    _scheduleTimer();
  }

  void rearmTimeout() {
    if (_watchdogTimeout == null || _watchdogCallback == null) return;
    _scheduleTimer();
  }

  void _scheduleTimer() {
    _timeoutTimer?.cancel();
    final timeout = _watchdogTimeout;
    final cb = _watchdogCallback;
    if (timeout == null || cb == null) return;
    _timeoutTimer = Timer(timeout, () {
      if (_completer.isCompleted) return;
      cb();
    });
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _watchdogTimeout = null;
    _watchdogCallback = null;
  }

  void complete() {
    cancelTimeout();
    if (_completer.isCompleted) return;
    _completer.complete(List.unmodifiable(frames));
    _settled.complete();
  }

  void completeError(Object error) {
    cancelTimeout();
    if (_completer.isCompleted) return;
    _completer.completeError(error);
    _settled.complete();
  }
}

/// One buffered transport write. Settles exactly once.
class _TransportPendingWrite {
  final Uint8List bytes;
  final Completer<void> _completer = Completer<void>();

  _TransportPendingWrite(this.bytes);

  Future<void> get future => _completer.future;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void fail(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
