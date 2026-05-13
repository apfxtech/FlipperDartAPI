part of 'flipper_client.dart';

enum FlipperLink { usb, ble }

enum FlipperMode { disconnected, cli, rpc }

enum FlipperRequestPriority {
  rightNow,
  foreground,
  defaultPriority,
  background,
}

class FlipperUnsupportedModeError extends StateError {
  FlipperUnsupportedModeError(super.message);
}

class FlipperRpcException implements Exception {
  final CommandStatus status;
  final int statusValue;
  final String statusName;
  final Main response;

  FlipperRpcException(this.response)
      : status = response.commandStatus,
        statusValue = response.commandStatus.value,
        statusName = response.commandStatus.name;

  @override
  String toString() => 'FlipperRpcException($statusName=$statusValue)';
}

class FlipperRpcGeneralException extends FlipperRpcException {
  FlipperRpcGeneralException(super.response);
}

class FlipperRpcDecodeException extends FlipperRpcException {
  FlipperRpcDecodeException(super.response);
}

class FlipperRpcNotImplementedException extends FlipperRpcException {
  FlipperRpcNotImplementedException(super.response);
}

class FlipperRpcBusyException extends FlipperRpcException {
  FlipperRpcBusyException(super.response);
}

class FlipperRpcContinuousCommandInterruptedException
    extends FlipperRpcException {
  FlipperRpcContinuousCommandInterruptedException(super.response);
}

class FlipperRpcInvalidParametersException extends FlipperRpcException {
  FlipperRpcInvalidParametersException(super.response);
}

class FlipperRpcStorageNotReadyException extends FlipperRpcException {
  FlipperRpcStorageNotReadyException(super.response);
}

class FlipperRpcStorageExistException extends FlipperRpcException {
  FlipperRpcStorageExistException(super.response);
}

class FlipperRpcStorageNotExistException extends FlipperRpcException {
  FlipperRpcStorageNotExistException(super.response);
}

class FlipperRpcStorageInvalidParameterException extends FlipperRpcException {
  FlipperRpcStorageInvalidParameterException(super.response);
}

class FlipperRpcStorageDeniedException extends FlipperRpcException {
  FlipperRpcStorageDeniedException(super.response);
}

class FlipperRpcStorageInvalidNameException extends FlipperRpcException {
  FlipperRpcStorageInvalidNameException(super.response);
}

class FlipperRpcStorageInternalException extends FlipperRpcException {
  FlipperRpcStorageInternalException(super.response);
}

class FlipperRpcStorageNotImplementedException extends FlipperRpcException {
  FlipperRpcStorageNotImplementedException(super.response);
}

class FlipperRpcStorageAlreadyOpenException extends FlipperRpcException {
  FlipperRpcStorageAlreadyOpenException(super.response);
}

class FlipperRpcStorageDirNotEmptyException extends FlipperRpcException {
  FlipperRpcStorageDirNotEmptyException(super.response);
}

class FlipperRpcAppCantStartException extends FlipperRpcException {
  FlipperRpcAppCantStartException(super.response);
}

class FlipperRpcAppSystemLockedException extends FlipperRpcException {
  FlipperRpcAppSystemLockedException(super.response);
}

class FlipperRpcAppNotRunningException extends FlipperRpcException {
  FlipperRpcAppNotRunningException(super.response);
}

class FlipperRpcAppCmdErrorException extends FlipperRpcException {
  FlipperRpcAppCmdErrorException(super.response);
}

class FlipperRpcVirtualDisplayAlreadyStartedException
    extends FlipperRpcException {
  FlipperRpcVirtualDisplayAlreadyStartedException(super.response);
}

class FlipperRpcVirtualDisplayNotStartedException extends FlipperRpcException {
  FlipperRpcVirtualDisplayNotStartedException(super.response);
}

class FlipperRpcGpioModeIncorrectException extends FlipperRpcException {
  FlipperRpcGpioModeIncorrectException(super.response);
}

class FlipperRpcGpioUnknownPinModeException extends FlipperRpcException {
  FlipperRpcGpioUnknownPinModeException(super.response);
}

FlipperRpcException? _exceptionFromResponse(Main response) {
  final status = response.commandStatus;
  if (status == CommandStatus.OK) return null;
  if (status == CommandStatus.ERROR_DECODE) {
    return FlipperRpcDecodeException(response);
  }
  if (status == CommandStatus.ERROR_NOT_IMPLEMENTED) {
    return FlipperRpcNotImplementedException(response);
  }
  if (status == CommandStatus.ERROR_BUSY) {
    return FlipperRpcBusyException(response);
  }
  if (status == CommandStatus.ERROR_CONTINUOUS_COMMAND_INTERRUPTED) {
    return FlipperRpcContinuousCommandInterruptedException(response);
  }
  if (status == CommandStatus.ERROR_INVALID_PARAMETERS) {
    return FlipperRpcInvalidParametersException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_NOT_READY) {
    return FlipperRpcStorageNotReadyException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_EXIST) {
    return FlipperRpcStorageExistException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_NOT_EXIST) {
    return FlipperRpcStorageNotExistException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_INVALID_PARAMETER) {
    return FlipperRpcStorageInvalidParameterException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_DENIED) {
    return FlipperRpcStorageDeniedException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_INVALID_NAME) {
    return FlipperRpcStorageInvalidNameException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_INTERNAL) {
    return FlipperRpcStorageInternalException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_NOT_IMPLEMENTED) {
    return FlipperRpcStorageNotImplementedException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_ALREADY_OPEN) {
    return FlipperRpcStorageAlreadyOpenException(response);
  }
  if (status == CommandStatus.ERROR_STORAGE_DIR_NOT_EMPTY) {
    return FlipperRpcStorageDirNotEmptyException(response);
  }
  if (status == CommandStatus.ERROR_APP_CANT_START) {
    return FlipperRpcAppCantStartException(response);
  }
  if (status == CommandStatus.ERROR_APP_SYSTEM_LOCKED) {
    return FlipperRpcAppSystemLockedException(response);
  }
  if (status == CommandStatus.ERROR_APP_NOT_RUNNING) {
    return FlipperRpcAppNotRunningException(response);
  }
  if (status == CommandStatus.ERROR_APP_CMD_ERROR) {
    return FlipperRpcAppCmdErrorException(response);
  }
  if (status == CommandStatus.ERROR_VIRTUAL_DISPLAY_ALREADY_STARTED) {
    return FlipperRpcVirtualDisplayAlreadyStartedException(response);
  }
  if (status == CommandStatus.ERROR_VIRTUAL_DISPLAY_NOT_STARTED) {
    return FlipperRpcVirtualDisplayNotStartedException(response);
  }
  if (status == CommandStatus.ERROR_GPIO_MODE_INCORRECT) {
    return FlipperRpcGpioModeIncorrectException(response);
  }
  if (status == CommandStatus.ERROR_GPIO_UNKNOWN_PIN_MODE) {
    return FlipperRpcGpioUnknownPinModeException(response);
  }
  return FlipperRpcGeneralException(response);
}

class FlipperDevice {
  final String id;
  final String name;
  final FlipperLink link;
  final DiscoveredDevice source;
  final int? vendorId;
  final int? productId;
  final String? serialNumber;
  final int? rssi;

  const FlipperDevice({
    required this.id,
    required this.name,
    required this.link,
    required this.source,
    this.vendorId,
    this.productId,
    this.serialNumber,
    this.rssi,
  });

  bool get isUsb => link == FlipperLink.usb;

  bool get isBle => link == FlipperLink.ble;
}

class FlipperRpcBatch<T extends $pb.GeneratedMessage> {
  final int commandId;
  final Main request;
  final List<Main> frames;
  final List<T> items;

  const FlipperRpcBatch({
    required this.commandId,
    required this.request,
    required this.frames,
    required this.items,
  });

  T get single => items.single;

  T? get firstOrNull => items.isEmpty ? null : items.first;
}

class FlipperConnectionState {
  final FlipperMode mode;
  final FlipperDevice? device;
  final bool connected;

  const FlipperConnectionState({
    required this.mode,
    required this.device,
    required this.connected,
  });
}

class FlipperClient {
  static const String bleServiceUuid = '8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000';
  static const String bleRxUuid = '19ed82ae-ed21-4c9d-4145-228e61fe0000';
  static const String bleTxUuid = '19ed82ae-ed21-4c9d-4145-228e62fe0000';
  static const String cliPrompt = '\r\n\r\n>: ';
  static const String startRpcSession = 'start_rpc_session\r';

  final _devicesCtrl = StreamController<List<FlipperDevice>>.broadcast();
  final _connectionCtrl = StreamController<FlipperConnectionState>.broadcast();
  final _modeCtrl = StreamController<FlipperMode>.broadcast();
  final _rawCtrl = StreamController<List<int>>.broadcast();
  final _textCtrl = StreamController<String>.broadcast();
  final _messageCtrl = StreamController<Main>.broadcast();
  final _broadcastCtrl = StreamController<Main>.broadcast();
  final _errorCtrl = StreamController<FlipperRpcException>.broadcast();

  final Map<String, FlipperDevice> _devices = {};
  final Map<int, _PendingRpc> _pendingRpc = {};
  final List<_QueuedRequest> _requestQueue = [];
  final _frameBuffer = _FrameBuffer();
  final _utf8Decoder = const Utf8Decoder(allowMalformed: true);

  Completer<void>? _queueSignal;
  bool _workerRunning = false;
  int _requestSeq = 0;
  int? _activeMultiFrameGroup;

  StreamSubscription<List<int>>? _transportSub;
  _Transport? _transport;
  FlipperDevice? _connectedDevice;
  FlipperMode _mode = FlipperMode.disconnected;
  int _nextCommandId = 1;
  bool _scanning = false;
  bool cliExclusive = false;
  Future<void>? _switchToRpcFuture;

  Stream<List<FlipperDevice>> get devicesStream => _devicesCtrl.stream;

  Stream<FlipperConnectionState> get connectionStream => _connectionCtrl.stream;

  Stream<FlipperMode> get modeStream => _modeCtrl.stream;

  Stream<List<int>> get rawBytesStream => _rawCtrl.stream;

  Stream<String> get textStream => _textCtrl.stream;

  Stream<Main> get messageStream => _messageCtrl.stream;

  Stream<Main> get broadcastStream => _broadcastCtrl.stream;

  Stream<Main> get notificationStream => _broadcastCtrl.stream;

  Stream<FlipperRpcException> get errorStream => _errorCtrl.stream;

  List<FlipperDevice> get devices => List.unmodifiable(_devices.values.toList());

  List<FlipperDevice> listDevices() => devices;

  FlipperDevice? get connectedDevice => _connectedDevice;

  FlipperMode get mode => _mode;

  bool get isConnected => _transport != null;

  bool get isScanning => _scanning;

  int nextCommandId() {
    do {
      _nextCommandId++;
      if (_nextCommandId > 0x7FFFFFFF) _nextCommandId = 1;
    } while (_nextCommandId == 0 || _pendingRpc.containsKey(_nextCommandId));
    return _nextCommandId;
  }

  Future<void> initialize() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _requestBlePermissions();
    }
  }

  Future<List<FlipperDevice>> refreshDevices({
    Duration bleTimeout = const Duration(seconds: 10),
  }) async {
    _devices.clear();
    await _loadUsbDevices();
    _emitDevices();
    await scanBle(timeout: bleTimeout);
    return devices;
  }

  Future<List<FlipperDevice>> searchDevices({
    Duration bleTimeout = const Duration(seconds: 10),
  }) {
    return refreshDevices(bleTimeout: bleTimeout);
  }

  Future<void> scanBle({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_scanning) return;

    final state = await uble.UniversalBle.getBluetoothAvailabilityState();
    if (state != uble.AvailabilityState.poweredOn) {
      LogService.log('[FlipperClient] BLE adapter state: $state');
      return;
    }

    _scanning = true;
    uble.UniversalBle.onScanResult = (device) {
      _rememberDevice(_fromDiscovered(BleDiscoveredDevice(device)));
    };

    await uble.UniversalBle.startScan();
    await Future.delayed(timeout);
    await stopScan();
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    await uble.UniversalBle.stopScan();
    uble.UniversalBle.onScanResult = null;
    _scanning = false;
    _emitDevices();
  }

  Future<FlipperDevice> connectById(
    String id, {
    FlipperLink? link,
  }) async {
    FlipperDevice? device;
    for (final candidate in devices) {
      if (candidate.id != id) continue;
      if (link != null && candidate.link != link) continue;
      device = candidate;
      break;
    }
    if (device == null) {
      throw StateError('Device not found: $id');
    }
    return connect(device);
  }

  Future<FlipperDevice> connect(FlipperDevice device) async {
    await disconnect();

    _Transport? transport;
    try {
      transport = await _openTransport(device);
      _transport = transport;
      _connectedDevice = device;
      _transportSub = transport.bytesStream.listen(
        _onTransportBytes,
        onError: _onTransportError,
        onDone: _onTransportDone,
      );

      await transport.open();
      _setMode(transport.initialMode);
      _startWorker();
      return device;
    } catch (_) {
      await _cleanupFailedConnect(transport);
      rethrow;
    }
  }

  Future<void> _cleanupFailedConnect(_Transport? transport) async {
    _transport = null;
    _connectedDevice = null;
    _frameBuffer.clear();

    await _transportSub?.cancel();
    _transportSub = null;

    _failAllPending(StateError('Disconnected'));

    if (transport != null) {
      try {
        await transport.close();
      } catch (_) {}
    }

    _setMode(FlipperMode.disconnected);
  }

  Future<void> disconnect() async {
    final transport = _transport;
    _transport = null;
    _frameBuffer.clear();

    await _transportSub?.cancel();
    _transportSub = null;

    _failAllPending(StateError('Disconnected'));

    if (transport != null) {
      try {
        await transport.close();
      } catch (_) {}
    }

    _connectedDevice = null;
    _setMode(FlipperMode.disconnected);
    _signalWorker();
  }

  void _failAllPending(Object error) {
    _activeMultiFrameGroup = null;
    for (final queued in _requestQueue) {
      queued.fail(error);
    }
    _requestQueue.clear();
    for (final pending in _pendingRpc.values) {
      pending.cancelTimeout();
      pending.completeError(error);
    }
    _pendingRpc.clear();
  }

  Future<void> switchToRpcMode() {
    if (cliExclusive) {
      return Future.error(
        StateError('RPC switch blocked: CLI session is active'),
      );
    }
    if (_mode == FlipperMode.rpc) return Future.value();
    return _switchToRpcFuture ??= _doSwitchToRpcMode().whenComplete(() {
      _switchToRpcFuture = null;
    });
  }

  Future<void> _doSwitchToRpcMode() async {
    final transport = _requireTransport();
    if (_mode == FlipperMode.rpc) return;
    if (!transport.supportsCli) {
      _setMode(FlipperMode.rpc);
      _signalWorker();
      return;
    }

    LogService.log('[RPC] waiting for CLI prompt...');
    try {
      await _ensureCliPrompt();
      LogService.log('[RPC] CLI prompt detected');
    } catch (e) {
      LogService.log('[RPC] CLI prompt timeout ($e), continuing anyway');
    }

    LogService.log('[RPC] sending start_rpc_session');
    try {
      await transport.writeAscii(FlipperClient.startRpcSession);
      await _waitForText(
        (text) => text.contains('start_rpc_session'),
        timeout: const Duration(seconds: 2),
      );
      LogService.log('[RPC] start_rpc_session echoed, flushing serial buffer...');
    } catch (e) {
      LogService.log('[RPC] start_rpc_session echo timeout ($e), may already be in RPC mode');
    }

    await Future<void>.delayed(const Duration(milliseconds: 150));
    _frameBuffer.clear();
    LogService.log('[RPC] mode switched to RPC');
    _setMode(FlipperMode.rpc);
    _signalWorker();
  }

  Future<void> enterRpcMode() => switchToRpcMode();

  Future<void> switchToCliMode() async {
    final device = _connectedDevice;
    if (device == null) {
      throw StateError('No device connected');
    }
    final transport = _requireTransport();
    if (!transport.supportsCli) {
      throw FlipperUnsupportedModeError(
        'CLI mode is not available on this transport',
      );
    }
    if (_mode == FlipperMode.cli) return;

    await disconnect();
    await connect(device);
    await _ensureCliPrompt();
  }

  Future<void> enterCliMode() => switchToCliMode();

  Future<String> executeCli(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_requireTransport().supportsCli) {
      throw FlipperUnsupportedModeError(
        'CLI commands are not available on this transport',
      );
    }
    if (_mode != FlipperMode.cli) {
      await switchToCliMode();
    }
    final transport = _requireTransport();
    final chunks = <String>[];
    final completer = Completer<String>();

    late final StreamSubscription<String> sub;
    sub = textStream.listen((chunk) {
      chunks.add(chunk);
      final full = chunks.join();
      if (full.contains(FlipperClient.cliPrompt) && !completer.isCompleted) {
        completer.complete(_trimCliResult(full, command));
      }
    });

    try {
      await transport.writeAscii('\r');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await transport.writeAscii('$command\r');
      return await completer.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  Future<void> writeCliText(String text) async {
    final transport = _requireTransport();
    if (!transport.supportsCli) {
      throw FlipperUnsupportedModeError(
        'CLI mode is not available on this transport',
      );
    }
    if (_mode == FlipperMode.rpc) {
      throw StateError('Cannot send CLI text while in RPC mode');
    }
    await transport.writeAscii(text);
  }

  Future<void> writeCliBytes(Uint8List bytes) async {
    final transport = _requireTransport();
    if (!transport.supportsCli) {
      throw FlipperUnsupportedModeError(
        'CLI mode is not available on this transport',
      );
    }
    if (_mode == FlipperMode.rpc) {
      throw StateError('Cannot send CLI bytes while in RPC mode');
    }
    await transport.write(bytes);
  }

  Future<List<FlipperDevice>> refreshUsbOnly() async {
    final usbKeyPrefix = '${FlipperLink.usb.name}:';
    _devices.removeWhere((key, _) => key.startsWith(usbKeyPrefix));
    await _loadUsbDevices();
    _emitDevices();
    return devices;
  }

  Future<String> executeCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return executeCli(command, timeout: timeout);
  }

  Future<void> sendRpc(
    Main message, {
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    if (message.commandId == 0) {
      message.commandId = nextCommandId();
    }
    final completer = Completer<void>();
    _enqueueRequest(
      _QueuedRequest(
        frame: message,
        priority: priority,
        seq: _requestSeq++,
        onSent: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      ),
    );
    await completer.future;
  }

  Future<List<Main>> callRpcFrames(
    Main request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    final commandId = request.commandId == 0 ? nextCommandId() : request.commandId;
    request.commandId = commandId;

    final pending = _PendingRpc(commandId);
    _pendingRpc[commandId] = pending;
    pending.armTimeout(timeout, () {
      _pendingRpc.remove(commandId);
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
      pending.completeError(
        TimeoutException('RPC timeout for commandId=$commandId'),
      );
    });

    _enqueueRequest(
      _QueuedRequest(
        frame: request,
        priority: priority,
        seq: _requestSeq++,
        onError: (error) {
          if (_pendingRpc.remove(commandId) != null) {
            pending.cancelTimeout();
            if (_activeMultiFrameGroup == commandId) {
              _activeMultiFrameGroup = null;
              _signalWorker();
            }
            pending.completeError(error);
          }
        },
      ),
    );

    try {
      return await pending.future;
    } finally {
      _pendingRpc.remove(commandId);
      pending.cancelTimeout();
    }
  }

  Future<List<Main>> callRpcFramesMulti(
    Future<void> Function(Future<void> Function(Main frame) sendFrame) body, {
    Duration timeout = const Duration(minutes: 15),
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    final commandId = nextCommandId();
    final pending = _PendingRpc(commandId);
    _pendingRpc[commandId] = pending;
    pending.armTimeout(timeout, () {
      _pendingRpc.remove(commandId);
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
      pending.completeError(
        TimeoutException('Multi-frame RPC timeout for commandId=$commandId'),
      );
    });

    var finalFrameSent = false;

    Future<void> sendFrame(Main frame) async {
      frame.commandId = commandId;
      final completer = Completer<void>();
      final wasFinal = !frame.hasNext;
      _enqueueRequest(
        _QueuedRequest(
          frame: frame,
          priority: priority,
          seq: _requestSeq++,
          onSent: () {
            if (wasFinal) finalFrameSent = true;
            if (!completer.isCompleted) completer.complete();
          },
          onError: (error) {
            if (!completer.isCompleted) completer.completeError(error);
          },
        ),
      );
      await completer.future;
    }

    try {
      try {
        await body(sendFrame);
      } catch (e) {
        if (_activeMultiFrameGroup == commandId) {
          _activeMultiFrameGroup = null;
          _signalWorker();
        }
        _pendingRpc.remove(commandId);
        pending.completeError(e);
        rethrow;
      }

      if (!finalFrameSent) {
        if (_activeMultiFrameGroup == commandId) {
          _activeMultiFrameGroup = null;
          _signalWorker();
        }
        _pendingRpc.remove(commandId);
        final err = StateError(
          'Multi-frame body completed without sending a final frame '
          '(hasNext=false) for commandId=$commandId',
        );
        pending.completeError(err);
        throw err;
      }

      return await pending.future;
    } finally {
      _pendingRpc.remove(commandId);
      pending.cancelTimeout();
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
    }
  }

  Future<FlipperRpcBatch<T>> callRpc<T extends $pb.GeneratedMessage>(
    Main request,
    T? Function(Main frame) pick, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    final frames = await callRpcFrames(
      request,
      timeout: timeout,
      priority: priority,
    );
    final items = <T>[];
    for (final frame in frames) {
      final item = pick(frame);
      if (item != null) {
        items.add(item);
      }
    }
    return FlipperRpcBatch<T>(
      commandId: request.commandId,
      request: request,
      frames: frames,
      items: items,
    );
  }

  Stream<T> select<T extends $pb.GeneratedMessage>(
    T? Function(Main frame) pick,
  ) {
    return messageStream.transform(
      StreamTransformer<Main, T>.fromHandlers(
        handleData: (frame, sink) {
          final selected = pick(frame);
          if (selected != null) {
            sink.add(selected);
          }
        },
      ),
    );
  }

  void _enqueueRequest(_QueuedRequest request) {
    var inserted = false;
    for (var i = 0; i < _requestQueue.length; i++) {
      if (request.compareTo(_requestQueue[i]) < 0) {
        _requestQueue.insert(i, request);
        inserted = true;
        break;
      }
    }
    if (!inserted) {
      _requestQueue.add(request);
    }
    _signalWorker();
  }

  void _signalWorker() {
    final signal = _queueSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
  }

  void _startWorker() {
    if (_workerRunning) return;
    _workerRunning = true;
    unawaited(_runWorker());
  }

  _QueuedRequest? _dequeueNext() {
    if (_requestQueue.isEmpty) return null;
    final lockedId = _activeMultiFrameGroup;
    if (lockedId != null) {
      final idx = _requestQueue.indexWhere(
        (r) => r.frame.commandId == lockedId,
      );
      if (idx < 0) return null;
      return _requestQueue.removeAt(idx);
    }
    return _requestQueue.removeAt(0);
  }

  Future<void> _runWorker() async {
    try {
      while (_transport != null) {
        _QueuedRequest? request;
        if (_mode == FlipperMode.rpc) {
          request = _dequeueNext();
        }
        if (request == null) {
          final signal = Completer<void>();
          _queueSignal = signal;
          if (_mode == FlipperMode.rpc && _dequeueNextPeek()) {
            _queueSignal = null;
            continue;
          }
          if (_transport == null) break;
          await signal.future;
          _queueSignal = null;
          continue;
        }

        final transport = _transport;
        if (transport == null) {
          request.fail(StateError('Disconnected'));
          continue;
        }

        final frame = request.frame;
        try {
          final encoded = _Protocol.encode(frame);
          LogService.log(
            '[RPC] tx cmdId=${frame.commandId} '
            'priority=${request.priority.name} '
            'hasNext=${frame.hasNext} '
            'content=${frame.whichContent().name} (${encoded.length} bytes)',
          );
          await transport.write(encoded);
          if (frame.commandId != 0) {
            if (frame.hasNext) {
              _activeMultiFrameGroup = frame.commandId;
            } else if (_activeMultiFrameGroup == frame.commandId) {
              _activeMultiFrameGroup = null;
            }
          }
          request.markSent();

          if (!frame.hasNext && frame.commandId != 0) {
            final pending = _pendingRpc[frame.commandId];
            if (pending != null) {
              LogService.log(
                '[RPC] waiting response for cmdId=${frame.commandId}',
              );
              try {
                await pending.future;
              } catch (_) {}
            }
          }
        } catch (error) {
          LogService.log('[RPC] tx error: $error');
          if (_activeMultiFrameGroup == frame.commandId) {
            _activeMultiFrameGroup = null;
          }
          request.fail(error);
        }
      }
    } finally {
      _workerRunning = false;
      _activeMultiFrameGroup = null;
      for (final queued in _requestQueue) {
        queued.fail(StateError('Worker stopped'));
      }
      _requestQueue.clear();
    }
  }

  bool _dequeueNextPeek() {
    if (_requestQueue.isEmpty) return false;
    final lockedId = _activeMultiFrameGroup;
    if (lockedId == null) return true;
    return _requestQueue.any((r) => r.frame.commandId == lockedId);
  }

  Future<List<FlipperDevice>> _loadUsbDevices() async {
    final result = <FlipperDevice>[];

    if (Platform.isAndroid) {
      final devices = await UsbSerial.listDevices();
      for (final device in devices) {
        result.add(
          FlipperDevice(
            id: '${device.vid}:${device.pid}',
            name: (device.productName?.isNotEmpty == true)
                ? device.productName!
                : 'USB VID:0x${device.vid?.toRadixString(16) ?? '?'} PID:0x${device.pid?.toRadixString(16) ?? '?'}',
            link: FlipperLink.usb,
            source: AndroidUsbDiscoveredDevice(device),
            vendorId: device.vid,
            productId: device.pid,
          ),
        );
      }
    } else {
      for (final portName in SerialPort.availablePorts) {
        final port = SerialPort(portName);
        try {
          result.add(
            FlipperDevice(
              id: portName,
              name: (port.description?.isNotEmpty == true)
                  ? port.description!
                  : portName,
              link: FlipperLink.usb,
              source: DesktopUsbDiscoveredDevice(
                portName,
                port.description ?? '',
                vendorId: port.vendorId,
                productId: port.productId,
                serialNumber: port.serialNumber,
              ),
              vendorId: port.vendorId,
              productId: port.productId,
              serialNumber: port.serialNumber,
            ),
          );
        } finally {
          port.dispose();
        }
      }
    }

    for (final device in result) {
      _rememberDevice(device);
    }
    return result;
  }

  FlipperDevice _fromDiscovered(DiscoveredDevice device) {
    if (device is BleDiscoveredDevice) {
      return FlipperDevice(
        id: device.id,
        name: device.name,
        link: FlipperLink.ble,
        source: device,
        rssi: device.rssi,
      );
    }
    if (device is DesktopUsbDiscoveredDevice) {
      return FlipperDevice(
        id: device.id,
        name: device.name,
        link: FlipperLink.usb,
        source: device,
        vendorId: device.vendorId,
        productId: device.productId,
        serialNumber: device.serialNumber,
      );
    }
    if (device is AndroidUsbDiscoveredDevice) {
      return FlipperDevice(
        id: device.id,
        name: device.name,
        link: FlipperLink.usb,
        source: device,
        vendorId: device.usbDevice.vid,
        productId: device.usbDevice.pid,
      );
    }
    throw UnsupportedError('Unsupported device: ${device.runtimeType}');
  }

  Future<_Transport> _openTransport(FlipperDevice device) {
    if (device.source is BleDiscoveredDevice) {
      return _BleTransport.create(device.source as BleDiscoveredDevice);
    }
    if (device.source is AndroidUsbDiscoveredDevice) {
      return _AndroidUsbTransport.create(
        device.source as AndroidUsbDiscoveredDevice,
      );
    }
    if (device.source is DesktopUsbDiscoveredDevice) {
      return _DesktopUsbTransport.create(
        device.source as DesktopUsbDiscoveredDevice,
      );
    }
    throw UnsupportedError('Unsupported device source: ${device.source.runtimeType}');
  }

  void _onTransportBytes(List<int> chunk) {
    _rawCtrl.add(chunk);

    if (_mode == FlipperMode.rpc) {
      final frames = _frameBuffer.push(chunk);
      if (frames.isEmpty) {
        LogService.log('[RPC] rx ${chunk.length} bytes, buffering (pending frame)');
        return;
      }
      for (final frame in frames) {
        _routeFrame(frame);
      }
      return;
    }

    final text = _utf8Decoder.convert(chunk);
    LogService.log('[CLI] rx: ${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}');
    _textCtrl.add(text);
  }

  void _routeFrame(Main frame) {
    _messageCtrl.add(frame);

    final commandId = frame.commandId;
    if (commandId == 0) {
      LogService.log(
        '[RPC] rx broadcast content=${frame.whichContent().name}',
      );
      _broadcastCtrl.add(frame);
      return;
    }

    final pending = _pendingRpc[commandId];
    if (pending == null) {
      LogService.log(
        '[RPC] rx frame cmdId=$commandId — no pending listener (unmatched)',
      );
      return;
    }

    LogService.log(
      '[RPC] rx frame cmdId=$commandId hasNext=${frame.hasNext} '
      'status=${frame.commandStatus.name} '
      'content=${frame.whichContent().name}',
    );
    pending.add(frame);

    if (!frame.hasNext) {
      _pendingRpc.remove(commandId);
      pending.cancelTimeout();
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
      final error = _exceptionFromResponse(frame);
      if (error != null) {
        if (!_errorCtrl.isClosed) _errorCtrl.add(error);
        pending.completeError(error);
      } else {
        pending.complete();
      }
    }
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    LogService.log('[FlipperClient] transport error: $error');
    if (_transport == null) return;
    unawaited(disconnect());
  }

  void _onTransportDone() {
    if (_transport == null) return;
    unawaited(disconnect());
  }

  Future<void> _requestBlePermissions() async {
    if (Platform.isIOS) {
      await Permission.bluetooth.request();
      return;
    }
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _ensureCliPrompt() async {
    final transport = _requireTransport();
    final completer = Completer<void>();
    final chunks = <String>[];

    late final StreamSubscription<String> sub;
    sub = textStream.listen((chunk) {
      chunks.add(chunk);
      if (chunks.join().contains(FlipperClient.cliPrompt) &&
          !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await transport.nudgeCli();
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('CLI prompt timeout'),
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _waitForText(
    bool Function(String text) test, {
    required Duration timeout,
  }) async {
    final completer = Completer<void>();
    final chunks = <String>[];

    late final StreamSubscription<String> sub;
    sub = textStream.listen((chunk) {
      chunks.add(chunk);
      if (test(chunks.join()) && !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  String _trimCliResult(String raw, String command) {
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final commandIndex = normalized.indexOf(command);
    final body = commandIndex >= 0
        ? normalized.substring(commandIndex + command.length)
        : normalized;
    final bodyPromptIndex = body.lastIndexOf('>: ');
    return (bodyPromptIndex >= 0 ? body.substring(0, bodyPromptIndex) : body)
        .trim();
  }

  void _rememberDevice(FlipperDevice device) {
    _devices['${device.link.name}:${device.id}'] = device;
    _emitDevices();
  }

  void _emitDevices() {
    final list = _devices.values.toList()
      ..sort((a, b) {
        final byLink = a.link.index.compareTo(b.link.index);
        if (byLink != 0) return byLink;
        return a.name.compareTo(b.name);
      });
    _devicesCtrl.add(List.unmodifiable(list));
  }

  _Transport _requireTransport() {
    final transport = _transport;
    if (transport == null) {
      throw StateError('No active transport');
    }
    return transport;
  }

  Future<void> dispose() async {
    await disconnect();
    await stopScan();
    await _devicesCtrl.close();
    await _connectionCtrl.close();
    await _modeCtrl.close();
    await _rawCtrl.close();
    await _textCtrl.close();
    await _messageCtrl.close();
    await _broadcastCtrl.close();
    await _errorCtrl.close();
  }

  void _setMode(FlipperMode mode) {
    _mode = mode;
    _modeCtrl.add(mode);
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: mode,
        device: _connectedDevice,
        connected: mode != FlipperMode.disconnected,
      ),
    );
  }
}

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

  Future<List<Main>> get future => _completer.future;

  void add(Main frame) {
    frames.add(frame);
  }

  void armTimeout(Duration timeout, void Function() onTimeout) {
    _timeoutTimer = Timer(timeout, () {
      if (_completer.isCompleted) return;
      onTimeout();
    });
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
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

class _Protocol {
  static Uint8List encode(Main message) {
    final payload = message.writeToBuffer();
    final prefix = _encodeVarint(payload.length);
    final buffer = Uint8List(prefix.length + payload.length);
    buffer.setRange(0, prefix.length, prefix);
    buffer.setRange(prefix.length, buffer.length, payload);
    return buffer;
  }

  static List<int> _encodeVarint(int value) {
    final bytes = <int>[];
    while (value > 0x7F) {
      bytes.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    bytes.add(value & 0x7F);
    return bytes;
  }
}

class _FrameBuffer {
  final List<int> _buffer = [];

  List<Main> push(List<int> chunk) {
    _buffer.addAll(chunk);
    final messages = <Main>[];
    while (true) {
      final frame = _tryParse();
      if (frame == null) return messages;
      messages.add(frame);
    }
  }

  void clear() => _buffer.clear();

  Main? _tryParse() {
    if (_buffer.isEmpty) return null;

    var length = 0;
    var shift = 0;
    var offset = 0;

    while (offset < _buffer.length) {
      final byte = _buffer[offset++];
      length |= (byte & 0x7F) << shift;
      shift += 7;

      if ((byte & 0x80) == 0) {
        if (length > 65536) {
          LogService.log(
            '[FrameBuffer] bad varint length=$length (0x${_buffer[0].toRadixString(16)}), dropping first byte',
          );
          _buffer.removeAt(0);
          return null;
        }
        if (_buffer.length < offset + length) {
          return null;
        }

        final payload =
            Uint8List.fromList(_buffer.sublist(offset, offset + length));
        _buffer.removeRange(0, offset + length);

        try {
          return Main.fromBuffer(payload);
        } catch (error) {
          LogService.log('[FrameBuffer] protobuf parse error (length=$length): $error');
          return null;
        }
      }

      if (shift >= 35) {
        LogService.log('[FrameBuffer] varint overflow, dropping first byte (0x${_buffer[0].toRadixString(16)})');
        _buffer.removeAt(0);
        return null;
      }
    }

    return null;
  }
}
