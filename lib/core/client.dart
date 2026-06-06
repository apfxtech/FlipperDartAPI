part of '../flipper_client.dart';

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
  final _deviceInfoCompleteCtrl =
      StreamController<Map<String, String>>.broadcast();
  bool _deviceInfoFetched = false;

  final _deviceInfoWatchCtrl = StreamController<Map<String, String>>.broadcast();
  int _collectionGen = 0;

  final Map<String, FlipperDevice> _devices = {};
  final Map<int, _PendingRpc> _pendingRpc = {};
  final List<_QueuedRequest> _requestQueue = [];
  final Map<String, String> _deviceInfoCache = {};
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

  List<FlipperDevice> get devices =>
      List.unmodifiable(_devices.values.toList());

  List<FlipperDevice> listDevices() => devices;

  FlipperDevice? get connectedDevice => _connectedDevice;

  Map<String, String> get deviceInfoCache => Map.unmodifiable(_deviceInfoCache);

  Stream<Map<String, String>> get deviceInfoStream =>
      _deviceInfoCompleteCtrl.stream;

  String? getName() =>
      _deviceInfoCache['hardware_name'] ?? _deviceInfoCache['device_name'];

  Future<String> awaitName() async {
    final cached = getName();
    if (cached != null && cached.isNotEmpty) return cached;

    await deviceInfoUpdates.firstWhere(
      (patch) =>
          (patch['hardware_name']?.isNotEmpty ?? false) ||
          (patch['device_name']?.isNotEmpty ?? false),
    );

    final name = getName();
    if (name == null || name.isEmpty) {
      throw StateError('Device info does not contain a device name');
    }
    return name;
  }

  Future<Map<String, String>> awaitDeviceInfo() {
    if (_deviceInfoFetched) return Future.value(deviceInfoCache);
    return deviceInfoStream.first;
  }

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
    await _blePlatform.requestPermissions();
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

  Future<void> scanBle({Duration timeout = const Duration(seconds: 10)}) async {
    if (_scanning) return;

    final state = await uble.UniversalBle.getBluetoothAvailabilityState();
    if (state != uble.AvailabilityState.poweredOn) {
      LogService.log('[FlipperClient] BLE adapter state: $state');
      return;
    }

    for (final device in await _blePlatform.loadKnownDevices()) {
      _rememberDevice(_fromDiscovered(device));
    }

    _scanning = true;
    final phaseResults = <BleDiscoveredDevice>[];
    uble.UniversalBle.onScanResult = (device) {
      final discovered = BleDiscoveredDevice(device);
      phaseResults.add(discovered);
      LogService.log(
        '[BLE] scan result id=${discovered.id} name=${discovered.name} '
        'rssi=${discovered.rssi} services=${device.services}',
      );
      _rememberDevice(_fromDiscovered(discovered));
    };

    final filters = _blePlatform.scanFilters.toList(growable: false);
    final phaseTimeout = filters.length <= 1
        ? timeout
        : Duration(
            milliseconds: (timeout.inMilliseconds ~/ filters.length).clamp(
              1000,
              timeout.inMilliseconds,
            ),
          );
    try {
      for (var i = 0; i < filters.length && _scanning; i++) {
        final filter = filters[i];
        LogService.log(
          '[BLE] start scan phase ${i + 1}/${filters.length} '
          'filterServices=${filter?.withServices ?? const <String>[]}',
        );
        phaseResults.clear();
        await uble.UniversalBle.startScan(scanFilter: filter);
        await Future.delayed(phaseTimeout);
        await uble.UniversalBle.stopScan();
        final resolved = await _blePlatform.resolveScanResults(phaseResults);
        if (resolved.isNotEmpty) {
          for (final device in resolved) {
            _rememberDevice(_fromDiscovered(device));
          }
          _emitDevices();
        }
        if (_hasFilteredBleDevice()) break;
      }
    } finally {
      uble.UniversalBle.onScanResult = null;
      _scanning = false;
      _emitDevices();
    }
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    await uble.UniversalBle.stopScan();
    uble.UniversalBle.onScanResult = null;
    _scanning = false;
    _emitDevices();
  }

  Future<FlipperDevice> connectById(String id, {FlipperLink? link}) async {
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
    // Stop any active scan before connecting.  On macOS this eliminates the
    // second CBCentralManager instance (universal_ble) from competing for
    // connection events, which otherwise halves effective BLE throughput.
    await stopScan();

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
    LogService.log('[FlipperClient] state -> disconnected: connect failed');
    _transport = null;
    _connectedDevice = null;
    _deviceInfoCache.clear();
    _deviceInfoFetched = false;
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
    LogService.log(
      '[FlipperClient] state -> disconnected: disconnect requested'
      '${transport == null ? ' (no active transport)' : ''}',
    );
    _transport = null;
    _switchToRpcFuture = null;
    _deviceInfoCache.clear();
    _deviceInfoFetched = false;
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
      if (_transport == transport) {
        _setMode(FlipperMode.rpc);
        _signalWorker();
      }
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
      LogService.log(
        '[RPC] start_rpc_session echoed, flushing serial buffer...',
      );
    } catch (e) {
      LogService.log(
        '[RPC] start_rpc_session echo timeout ($e), may already be in RPC mode',
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 150));
    _frameBuffer.clear();
    LogService.log('[RPC] mode switched to RPC');
    if (_transport == transport) {
      _setMode(FlipperMode.rpc);
      _signalWorker();
    }
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
    void Function(Main frame)? onFrame,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    final commandId = request.commandId == 0
        ? nextCommandId()
        : request.commandId;
    request.commandId = commandId;

    final pending = _PendingRpc(commandId)..onFrame = onFrame;
    _pendingRpc[commandId] = pending;
    void armTimeout() {
      pending.armTimeout(timeout, () {
        _pendingRpc.remove(commandId);
        _removeQueuedCommand(commandId, 'RPC timeout before TX');
        if (_activeMultiFrameGroup == commandId) {
          _activeMultiFrameGroup = null;
          _signalWorker();
        }
        pending.completeError(
          TimeoutException(
            'RPC timeout for commandId=$commandId '
            'after ${timeout.inSeconds}s framesReceived=${pending.frames.length}',
          ),
        );
      });
    }

    void failPending(Object error) {
      _pendingRpc.remove(commandId);
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
      pending.cancelTimeout();
      pending.completeError(error);
    }

    _enqueueRequest(
      _QueuedRequest(
        frame: request,
        priority: priority,
        seq: _requestSeq++,
        onSent: armTimeout,
        onError: (error) {
          if (_pendingRpc.remove(commandId) != null) {
            failPending(error);
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
    Duration timeout = const Duration(seconds: 60),
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    final commandId = nextCommandId();
    final pending = _PendingRpc(commandId);
    _pendingRpc[commandId] = pending;
    var finalFrameSent = false;
    var timeoutArmed = false;

    void armOrRearmTimeout() {
      if (timeoutArmed) {
        pending.rearmTimeout();
        return;
      }
      timeoutArmed = true;
      pending.armTimeout(timeout, () {
        _pendingRpc.remove(commandId);
        _removeQueuedCommand(commandId, 'multi-frame RPC timeout before TX');
        if (_activeMultiFrameGroup == commandId) {
          _activeMultiFrameGroup = null;
          _signalWorker();
        }
        pending.completeError(
          TimeoutException(
            'Multi-frame RPC timeout waiting for ACK commandId=$commandId '
            'after ${timeout.inSeconds}s finalFrameSent=$finalFrameSent '
            'queued=${_requestQueue.length} pending=${_pendingRpc.keys.toList()}',
          ),
        );
      });
    }

    void failPending(Object error) {
      _pendingRpc.remove(commandId);
      if (_activeMultiFrameGroup == commandId) {
        _activeMultiFrameGroup = null;
        _signalWorker();
      }
      pending.cancelTimeout();
      pending.completeError(error);
    }

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
            armOrRearmTimeout();
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
        failPending(e);
        rethrow;
      }

      if (!finalFrameSent) {
        final err = StateError(
          'Multi-frame body completed without sending a final frame '
          '(hasNext=false) for commandId=$commandId',
        );
        failPending(err);
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
    void Function(Main frame)? onFrame,
  }) async {
    final frames = await callRpcFrames(
      request,
      timeout: timeout,
      priority: priority,
      onFrame: onFrame,
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

  void _removeQueuedCommand(int commandId, String reason) {
    final before = _requestQueue.length;
    _requestQueue.removeWhere((r) => r.frame.commandId == commandId);
    final removed = before - _requestQueue.length;
    if (removed > 0) {
      LogService.log(
        '[RPC] removed $removed queued frame(s) for cmdId=$commandId: $reason',
      );
    }
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
      if (_transport != null) {
        _startWorker();
      }
    }
  }

  bool _dequeueNextPeek() {
    if (_requestQueue.isEmpty) return false;
    final lockedId = _activeMultiFrameGroup;
    if (lockedId == null) return true;
    return _requestQueue.any((r) => r.frame.commandId == lockedId);
  }

  Future<List<FlipperDevice>> _loadUsbDevices() async {
    final result = await _usbPlatform.loadDevices();
    for (final device in result) {
      _rememberDevice(device);
    }
    return result;
  }

  bool _hasFilteredBleDevice() {
    return _devices.values.any(
      (device) => device.isBle && isFlipperDevice(device),
    );
  }

  bool isFlipperDevice(FlipperDevice device) {
    final source = device.source;
    if (source is BleDiscoveredDevice) {
      return _blePlatform.includeDevice(source);
    }
    if (source is UsbDiscoveredDevice) {
      return _usbPlatform.includeDevice(device);
    }
    return false;
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
      return _blePlatform.openTransport(device.source as BleDiscoveredDevice);
    }
    if (device.source is UsbDiscoveredDevice) {
      return _usbPlatform.openTransport(device.source as UsbDiscoveredDevice);
    }
    throw UnsupportedError(
      'Unsupported device source: ${device.source.runtimeType}',
    );
  }

  void _onTransportBytes(List<int> chunk) {
    _rawCtrl.add(chunk);

    if (_mode == FlipperMode.rpc) {
      final result = _frameBuffer.push(chunk, onParseError: _onFrameParseError);
      if (result.frames.isEmpty) {
        LogService.log(
          '[RPC] rx ${chunk.length} bytes, buffering (pending frame) '
          '${result.pendingState ?? '<no state>'}',
        );
        return;
      }
      for (final frame in result.frames) {
        _routeFrame(frame);
      }
      if (result.pendingState != null) {
        LogService.log(
          '[RPC] parsed ${result.frames.length} frame(s), residual '
          '${result.pendingState}',
        );
      }
      return;
    }

    final text = _utf8Decoder.convert(chunk);
    LogService.log(
      '[CLI] rx: ${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}',
    );
    _textCtrl.add(text);
  }

  void _routeFrame(Main frame) {
    _messageCtrl.add(frame);

    if (frame.hasSystemDeviceInfoResponse()) {
      final info = frame.systemDeviceInfoResponse;
      final key = info.key.trim();
      final value = info.value.trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        _deviceInfoCache[key] = value;
        if (!_deviceInfoWatchCtrl.isClosed) {
          _deviceInfoWatchCtrl.add({key: value});
        }
      }
    }

    final commandId = frame.commandId;
    if (commandId == 0) {
      LogService.log('[RPC] rx broadcast content=${frame.whichContent().name}');
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
      'content=${frame.whichContent().name} '
      'frameN=${pending.frames.length + 1}',
    );
    pending.add(frame);

    if (frame.hasNext) {
      pending.rearmTimeout();
      return;
    }

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

  void _onFrameParseError(Object error) {
    final transport = _transport;
    if (transport == null) return;
    unawaited(
      transport.restartRpc().catchError((e) {
        LogService.log('[RPC] restart failed after parse error: $e');
      }),
    );
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    LogService.log('[FlipperClient] transport error: $error');
    if (_transport == null) return;
    LogService.log(
      '[FlipperClient] state -> disconnected: transport stream error',
    );
    unawaited(disconnect());
  }

  void _onTransportDone() {
    if (_transport == null) return;
    LogService.log(
      '[FlipperClient] state -> disconnected: transport stream closed',
    );
    unawaited(disconnect());
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
    await _deviceInfoCompleteCtrl.close();
    await _deviceInfoWatchCtrl.close();
  }

  void _setMode(FlipperMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _modeCtrl.add(mode);
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: mode,
        device: _connectedDevice,
        connected: mode != FlipperMode.disconnected,
      ),
    );
    if (mode == FlipperMode.rpc && getName() == null) {
      unawaited(_autoFetchDeviceInfo());
    }
  }

  Future<void> _autoFetchDeviceInfo() async {
    try {
      await deviceInfo(priority: FlipperRequestPriority.foreground);
      _deviceInfoFetched = true;
      final snapshot = deviceInfoCache;
      if (!_deviceInfoWatchCtrl.isClosed) {
        _deviceInfoWatchCtrl.add(snapshot);
      }
      if (!_deviceInfoCompleteCtrl.isClosed) {
        _deviceInfoCompleteCtrl.add(snapshot);
      }
    } catch (_) {}
  }
}
