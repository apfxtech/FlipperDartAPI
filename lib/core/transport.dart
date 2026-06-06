part of '../flipper_client.dart';

class FlipperTransportError implements Exception {
  final String message;

  FlipperTransportError(this.message);

  @override
  String toString() => message;
}

abstract class _Transport {
  final _bytesCtrl = StreamController<List<int>>.broadcast();
  final List<_TransportPendingWrite> _writeQueue = [];
  bool _writePumpRunning = false;
  bool _closed = false;
  bool _closing = false;

  Stream<List<int>> get bytesStream => _bytesCtrl.stream;

  bool get isClosed => _closed;

  void addBytes(List<int> bytes) {
    if (_closed || _bytesCtrl.isClosed) return;
    _bytesCtrl.add(bytes);
  }

  bool get supportsCli;

  FlipperMode get initialMode;

  int get storageChunkSize => _UniversalBleTransportBase._bleChunkSize;

  Future<void> open();

  Future<void> write(Uint8List bytes) {
    if (_closed || _closing) {
      return Future.error(StateError('Transport closed'));
    }
    final completer = Completer<void>();
    _writeQueue.add(_TransportPendingWrite(bytes, completer));
    _startWritePump();
    return completer.future;
  }

  void _startWritePump() {
    if (_writePumpRunning) return;
    _writePumpRunning = true;
    unawaited(_runWritePump());
  }

  Future<void> _runWritePump() async {
    try {
      while (_writeQueue.isNotEmpty && !_closed) {
        final pending = _writeQueue.removeAt(0);
        if (_closed || _closing) {
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(StateError('Transport closed'));
          }
          continue;
        }
        try {
          await rawWrite(pending.bytes);
          if (!pending.completer.isCompleted) pending.completer.complete();
        } catch (error) {
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(error);
          }
        }
      }
    } finally {
      _writePumpRunning = false;
    }
  }

  Future<void> rawWrite(Uint8List bytes);

  Future<void> restartRpc() async {}

  Future<void> writeAscii(String text) =>
      write(Uint8List.fromList(ascii.encode(text)));

  Future<void> nudgeCli();

  void _failPendingWrites(Object error) {
    while (_writeQueue.isNotEmpty) {
      final pending = _writeQueue.removeAt(0);
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
  }

  void onTransportFault(Object error) {
    if (_closed) return;
    _closed = true;
    LogService.log('[Transport] fault: $error');
    _failPendingWrites(error);
    onFaultExtra(error);
    if (!_bytesCtrl.isClosed) {
      _bytesCtrl.close();
    }
  }

  void onFaultExtra(Object error) {}

  Future<void> close() async {
    if (_closed) {
      _failPendingWrites(StateError('Transport closed'));
      return;
    }
    _closing = true;
    _failPendingWrites(StateError('Transport closed'));
    try {
      await doClose();
    } catch (e) {
      LogService.log('[Transport] doClose error: $e');
    }
    _closed = true;
    _closing = false;
    if (!_bytesCtrl.isClosed) {
      await _bytesCtrl.close();
    }
  }

  Future<void> doClose();
}
