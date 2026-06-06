part of '../flipper_client.dart';

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

  void cancelTimeout() {}

  @override
  int compareTo(_QueuedRequest other) {
    final byPriority = priority.index.compareTo(other.priority.index);
    if (byPriority != 0) return byPriority;
    return seq.compareTo(other.seq);
  }
}

class _PendingRpc {
  final int commandId;
  final List<Main> frames = [];
  final Completer<List<Main>> _completer = Completer<List<Main>>();
  Timer? _timeoutTimer;

  _PendingRpc(this.commandId);

  void Function(Main frame)? onFrame;

  Future<List<Main>> get future => _completer.future;

  void add(Main frame) {
    frames.add(frame);
    onFrame?.call(frame);
  }

  Duration? _watchdogTimeout;
  void Function()? _watchdogCallback;

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
    if (!_completer.isCompleted) {
      _completer.complete(List.unmodifiable(frames));
    }
  }

  void completeError(Object error) {
    cancelTimeout();
    if (!_completer.isCompleted) {
      _completer.completeError(error);
    }
  }
}

class _TransportPendingWrite {
  final Uint8List bytes;
  final Completer<void> completer;

  _TransportPendingWrite(this.bytes, this.completer);
}
