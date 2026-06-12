part of '../flipper_client.dart';

class FlipperClient {
  static const String bleServiceUuid = '8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000';
  static const String bleRxUuid = '19ed82ae-ed21-4c9d-4145-228e61fe0000';
  static const String bleTxUuid = '19ed82ae-ed21-4c9d-4145-228e62fe0000';
  static const String cliPrompt = '\r\n\r\n>: ';
  static const String startRpcSession = 'start_rpc_session\r';

  // Consecutive RX parse failures tolerated before the session is declared
  // desynchronized and closed.
  static const int _maxRxParseErrorStreak = 3;

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
  final _deviceInfoWatchCtrl =
      StreamController<Map<String, String>>.broadcast();

  final Map<String, FlipperDevice> _devices = {};
  final Map<int, _PendingRpc> _pendingRpc = {};
  final List<_QueuedRequest> _requestQueue = [];
  final Map<String, String> _deviceInfoCache = {};
  final _frameBuffer = _FrameBuffer();
  final _utf8Decoder = const Utf8Decoder(allowMalformed: true);

  // All lifecycle transitions (connect, disconnect, CLI re-connect, fault
  // teardown) run strictly one after another through this chain, so two
  // transports can never be opened concurrently and a teardown can never
  // interleave with a connect.
  Future<void> _lifecycleChain = Future.value();

  // _sessionGen increments on every connect / teardown. Long-lived async tasks
  // capture the generation they were started for and bail out when it no
  // longer matches, so a stale task can never touch a newer session's state.
  int _sessionGen = 0;
  _Transport? _transport;
  StreamSubscription<List<int>>? _transportSub;
  FlipperDevice? _connectedDevice;
  FlipperMode _mode = FlipperMode.disconnected;
  Future<void>? _switchToRpcFuture;
  Future<void>? _deviceInfoFetch;
  bool cliExclusive = false;
  bool _deviceInfoFetched = false;
  int _collectionGen = 0;
  int _rxParseErrorStreak = 0;

  Completer<void>? _queueSignal;
  int? _workerGen;
  int _requestSeq = 0;
  _QueuedRequest? _activeRequest;
  // While a multi-frame request group is being transmitted, only frames of
  // that commandId may leave the queue; everything else waits.
  int? _txGroupCommandId;

  int _nextCommandId = 1;
  bool _scanning = false;
  Completer<void>? _scanPhaseInterrupt;

  Stream<List<FlipperDevice>> get devicesStream => _devicesCtrl.stream;

  Stream<FlipperConnectionState> get connectionStream => _connectionCtrl.stream;

  Stream<FlipperMode> get modeStream => _modeCtrl.stream;

  Stream<List<int>> get rawBytesStream => _rawCtrl.stream;

  Stream<String> get textStream => _textCtrl.stream;

  Stream<Main> get messageStream => _messageCtrl.stream;

  Stream<Main> get broadcastStream => _broadcastCtrl.stream;

  Stream<Main> get notificationStream => _broadcastCtrl.stream;

  Stream<FlipperRpcException> get errorStream => _errorCtrl.stream;

  // USB hotplug events: native attach/detach broadcasts on Android, port-set
  // diffs on desktop. Listeners call refreshUsbOnly in response.
  Stream<void> get usbEvents => _usbPlatform.usbEvents;

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

    _ensureDeviceInfoFetch();
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
    _ensureDeviceInfoFetch();
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
    uble.UniversalBle.onScanResult = (device) {
      final discovered = BleDiscoveredDevice(device);
      LogService.log(
        '[BLE] scan result id=${discovered.id} name=${discovered.name} '
        'rssi=${discovered.rssi} services=${device.services}',
      );
      _rememberDevice(_fromDiscovered(discovered));
      if (_hasFilteredBleDevice()) _interruptScanPhase();
    };

    try {
      // Single phase scanning every advertising device: Flipper identification
      // is name/service based (includeDevice), so the UI filter can also
      // reveal non-Flipper devices on demand.
      LogService.log('[BLE] scan started');
      await uble.UniversalBle.startScan();
      final interrupt = _scanPhaseInterrupt = Completer<void>();
      await Future.any([Future.delayed(timeout), interrupt.future]);
      if (identical(_scanPhaseInterrupt, interrupt)) _scanPhaseInterrupt = null;
    } finally {
      await uble.UniversalBle.stopScan();
      uble.UniversalBle.onScanResult = null;
      _scanning = false;
      _emitDevices();
    }
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    _interruptScanPhase();
    await uble.UniversalBle.stopScan();
    uble.UniversalBle.onScanResult = null;
    _scanning = false;
    _emitDevices();
  }

  void _interruptScanPhase() {
    final interrupt = _scanPhaseInterrupt;
    _scanPhaseInterrupt = null;
    if (interrupt != null && !interrupt.isCompleted) interrupt.complete();
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

  Future<FlipperDevice> connect(FlipperDevice device) =>
      _serialized(() => _connectLocked(device));

  Future<void> disconnect() =>
      _serialized(() => _teardownLocked('disconnect requested'));

  // Appends a lifecycle operation to the chain. The chain never breaks: a
  // failed operation surfaces its error to its own caller only.
  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _lifecycleChain.then((_) => op());
    _lifecycleChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // Teardown for faults reported by callbacks. Bound to the generation that
  // faulted: by the time the chain reaches it, a newer session may already be
  // up and must not be killed.
  void _scheduleTeardown(int gen, Object reason) {
    unawaited(
      _serialized(() async {
        if (gen != _sessionGen) return;
        await _teardownLocked(reason);
      }),
    );
  }

  Future<FlipperDevice> _connectLocked(
    FlipperDevice device, {
    bool autoRpc = true,
  }) async {
    await _teardownLocked('replaced by connect to ${device.name}');
    // A running scan competes with the connection for the radio (on macOS a
    // second CBCentralManager halves effective throughput).
    await stopScan();

    final gen = ++_sessionGen;
    LogService.log(
      '[FlipperClient] connecting to ${device.name} '
      '(${device.link.name}:${device.id})',
    );
    _Transport? transport;
    try {
      transport = await _openTransport(device);
      await transport.open();
    } catch (error) {
      LogService.log(
        '[FlipperClient] connect failed '
        'device=${device.name} link=${device.link.name}: $error',
      );
      await transport?.close();
      rethrow;
    }

    if (gen != _sessionGen) {
      await transport.close();
      throw StateError('Connection attempt superseded');
    }

    _transport = transport;
    _connectedDevice = device;
    _transportSub = transport.bytesStream.listen(
      _onTransportBytes,
      onError: (Object error, StackTrace stackTrace) {
        // Transports report failures via onTransportFault and never put error
        // events on bytesStream; defensive guard against a misbehaving
        // backend.
        LogService.log('[FlipperClient] transport stream error: $error');
        _scheduleTeardown(gen, error);
      },
      onDone: () => _onTransportClosed(transport!),
    );

    _setMode(transport.initialMode);
    _startWorker(gen);
    LogService.log('[FlipperClient] connected to ${device.name}');
    if (autoRpc && transport.supportsCli) {
      unawaited(
        switchToRpcMode().catchError((Object error) {
          LogService.log('[FlipperClient] automatic RPC switch failed: $error');
        }),
      );
    }
    return device;
  }

  // The single teardown path for every way a session ends. Detaches all
  // session state synchronously before the first await, so late transport
  // callbacks always see a consistent disconnected picture.
  Future<void> _teardownLocked(Object reason) async {
    _sessionGen++;
    final transport = _transport;
    if (transport == null && _mode == FlipperMode.disconnected) {
      return;
    }

    final sub = _transportSub;
    _transport = null;
    _transportSub = null;
    _connectedDevice = null;
    _switchToRpcFuture = null;
    _deviceInfoFetch = null;
    _deviceInfoCache.clear();
    _deviceInfoFetched = false;
    _frameBuffer.clear();
    _rxParseErrorStreak = 0;

    final requestError = reason is Exception
        ? reason
        : StateError('Disconnected: $reason');
    _failAllRequests(requestError);
    _setMode(FlipperMode.disconnected, closeReason: reason);
    _signalWorker();

    if (sub != null) await sub.cancel();
    if (transport != null) await transport.close();
  }

  void _onTransportClosed(_Transport transport) {
    if (!identical(_transport, transport)) return;
    final reason = transport.closeReason ?? 'transport closed';
    final active = _activeRequest;
    final detailedReason = active == null
        ? reason
        : FlipperTransportError('$reason; active ${active.describe()}');
    LogService.log('[FlipperClient] transport closed: $detailedReason');
    _scheduleTeardown(_sessionGen, detailedReason);
  }

  void _failAllRequests(Object error) {
    _txGroupCommandId = null;
    _activeRequest = null;
    final queued = List<_QueuedRequest>.from(_requestQueue);
    _requestQueue.clear();
    for (final request in queued) {
      request.fail(error);
    }
    final pending = List<_PendingRpc>.from(_pendingRpc.values);
    _pendingRpc.clear();
    for (final p in pending) {
      p.completeError(error);
    }
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
      if (identical(_transport, transport)) {
        _setMode(FlipperMode.rpc);
        _signalWorker();
      }
      return;
    }

    final promptSeen = await _waitForTextMatch(
      (text) => text.contains(FlipperClient.cliPrompt),
      timeout: const Duration(seconds: 5),
      trigger: transport.nudgeCli,
    );
    LogService.log(
      promptSeen
          ? '[RPC] CLI prompt detected'
          : '[RPC] CLI prompt not seen within 5s, continuing',
    );
    if (!identical(_transport, transport)) return;

    final echoed = await _waitForTextMatch(
      (text) => text.contains('start_rpc_session'),
      timeout: const Duration(seconds: 2),
      trigger: () => transport.writeAscii(FlipperClient.startRpcSession),
    );
    LogService.log(
      echoed
          ? '[RPC] start_rpc_session echo received'
          : '[RPC] start_rpc_session echo not seen, may already be in RPC mode',
    );

    // Let trailing CLI bytes drain before treating the stream as protobuf.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!identical(_transport, transport)) return;
    _frameBuffer.clear();
    _setMode(FlipperMode.rpc);
    _signalWorker();
    LogService.log('[RPC] RPC mode active');
  }

  Future<void> enterRpcMode() => switchToRpcMode();

  Future<void> switchToCliMode() => _serialized(_switchToCliLocked);

  Future<void> _switchToCliLocked() async {
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

    // The firmware offers no RPC->CLI switch; the session is recreated.
    // autoRpc is off so the automatic RPC switch cannot race the CLI prompt.
    await _teardownLocked('switching to CLI mode');
    await _connectLocked(device, autoRpc: false);
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
    String result = '';
    final matched = await _waitForTextMatch(
      (text) {
        if (!text.contains(FlipperClient.cliPrompt)) return false;
        result = _trimCliResult(text, command);
        return true;
      },
      timeout: timeout,
      trigger: () async {
        await transport.writeAscii('\r');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await transport.writeAscii('$command\r');
      },
    );
    if (!matched) {
      throw TimeoutException('CLI command timeout: $command');
    }
    return result;
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
    final sent = Completer<void>();
    _enqueueRequest(
      _QueuedRequest(
        frame: message,
        priority: priority,
        seq: _requestSeq++,
        onSent: () {
          if (!sent.isCompleted) sent.complete();
        },
        onError: (error) {
          if (!sent.isCompleted) sent.completeError(error);
        },
      ),
    );
    await sent.future;
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

    _enqueueRequest(
      _QueuedRequest(
        frame: request,
        priority: priority,
        seq: _requestSeq++,
        onSent: () => pending.armTimeout(timeout, () {
          _onRpcTimeout(
            commandId,
            'RPC timeout for commandId=$commandId '
            'after ${timeout.inSeconds}s '
            'framesReceived=${pending.frames.length}',
          );
        }),
        onError: (error) => _failPendingById(commandId, error),
      ),
    );

    try {
      return await pending.future;
    } finally {
      _pendingRpc.remove(commandId);
      _releaseTxGroup(commandId);
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
        _onRpcTimeout(
          commandId,
          'Multi-frame RPC timeout waiting for ACK commandId=$commandId '
          'after ${timeout.inSeconds}s finalFrameSent=$finalFrameSent '
          'queued=${_requestQueue.length} pending=${_pendingRpc.keys.toList()}',
        );
      });
    }

    Future<void> sendFrame(Main frame) {
      frame.commandId = commandId;
      final sent = Completer<void>();
      final isFinal = !frame.hasNext;
      _enqueueRequest(
        _QueuedRequest(
          frame: frame,
          priority: priority,
          seq: _requestSeq++,
          onSent: () {
            if (isFinal) finalFrameSent = true;
            armOrRearmTimeout();
            if (!sent.isCompleted) sent.complete();
          },
          onError: (error) {
            if (!sent.isCompleted) sent.completeError(error);
          },
        ),
      );
      return sent.future;
    }

    try {
      try {
        await body(sendFrame);
      } catch (e) {
        _failPendingById(commandId, e);
        rethrow;
      }

      if (!finalFrameSent) {
        final err = StateError(
          'Multi-frame body completed without sending a final frame '
          '(hasNext=false) for commandId=$commandId',
        );
        _failPendingById(commandId, err);
        throw err;
      }

      return await pending.future;
    } finally {
      _pendingRpc.remove(commandId);
      _releaseTxGroup(commandId);
      pending.cancelTimeout();
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

  void _onRpcTimeout(int commandId, String message) {
    final active = _activeRequest;
    final detailed = active == null
        ? message
        : '$message; active ${active.describe()}';
    LogService.log('[RPC] timeout: $detailed');
    final pending = _pendingRpc.remove(commandId);
    _removeQueuedCommand(commandId, 'timeout before TX');
    _releaseTxGroup(commandId);
    pending?.completeError(TimeoutException(detailed));
  }

  void _failPendingById(int commandId, Object error) {
    final pending = _pendingRpc.remove(commandId);
    _removeQueuedCommand(commandId, 'request failed');
    _releaseTxGroup(commandId);
    pending?.completeError(error);
  }

  void _releaseTxGroup(int commandId) {
    if (_txGroupCommandId != commandId) return;
    _txGroupCommandId = null;
    _signalWorker();
  }

  // Removed requests are failed, never dropped silently: a multi-frame body
  // awaiting sendFrame() must observe the failure instead of hanging.
  void _removeQueuedCommand(int commandId, String reason) {
    final removed = <_QueuedRequest>[];
    _requestQueue.removeWhere((r) {
      if (r.frame.commandId != commandId) return false;
      removed.add(r);
      return true;
    });
    if (removed.isEmpty) return;
    LogService.log(
      '[RPC] dropped ${removed.length} queued frame(s) '
      'for cmdId=$commandId: $reason',
    );
    for (final request in removed) {
      request.fail(StateError('Request dropped: $reason'));
    }
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
    _queueSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _startWorker(int gen) {
    if (_workerGen == gen) return;
    _workerGen = gen;
    unawaited(_runWorker(gen));
  }

  _QueuedRequest? _dequeueNext() {
    if (_requestQueue.isEmpty) return null;
    final lockedId = _txGroupCommandId;
    if (lockedId != null) {
      final idx = _requestQueue.indexWhere(
        (r) => r.frame.commandId == lockedId,
      );
      if (idx < 0) return null;
      return _requestQueue.removeAt(idx);
    }
    return _requestQueue.removeAt(0);
  }

  bool _hasDispatchableRequest() {
    if (_requestQueue.isEmpty) return false;
    final lockedId = _txGroupCommandId;
    if (lockedId == null) return true;
    return _requestQueue.any((r) => r.frame.commandId == lockedId);
  }

  // The only writer in RPC mode. One frame is on the wire at a time; after
  // the final frame of a command the worker waits for the response — the
  // firmware serializes RPC handlers anyway, and this keeps its 1024-byte
  // input buffer from accumulating multiple commands.
  Future<void> _runWorker(int gen) async {
    while (gen == _sessionGen) {
      final transport = _transport;
      if (transport == null) break;

      _QueuedRequest? request;
      if (_mode == FlipperMode.rpc) {
        request = _dequeueNext();
      }
      if (request == null) {
        final signal = _queueSignal ??= Completer<void>();
        if (_mode == FlipperMode.rpc && _hasDispatchableRequest()) {
          // A request slipped in between dequeue and signal registration.
          continue;
        }
        await signal.future;
        continue;
      }

      final frame = request.frame;
      final encoded = _Protocol.encode(frame);
      _activeRequest = request;

      Object? writeError;
      try {
        await transport.write(encoded);
      } catch (error) {
        writeError = error;
      }
      if (gen != _sessionGen) {
        // Session ended while writing; teardown already failed the pending
        // state, settle the queue entry.
        request.fail(writeError ?? StateError('Disconnected'));
        break;
      }
      if (writeError != null) {
        LogService.log('[RPC] tx failed ${request.describe()}: $writeError');
        _activeRequest = null;
        _releaseTxGroup(frame.commandId);
        request.fail(
          FlipperTransportError(
            'RPC write failed for ${request.describe()}: $writeError',
          ),
        );
        // A dead transport announces itself through its done event, which
        // schedules the teardown.
        continue;
      }
      LogService.log('[RPC] tx ok ${request.describe()} bytes=${encoded.length}');

      if (frame.commandId != 0 && frame.hasNext) {
        _txGroupCommandId = frame.commandId;
      }
      request.markSent();

      if (frame.commandId != 0 && !frame.hasNext) {
        _releaseTxGroup(frame.commandId);
        final pending = _pendingRpc[frame.commandId];
        if (pending != null) {
          // Settles on response, timeout or teardown — never hangs.
          await pending.settled;
        }
      }
      if (identical(_activeRequest, request)) _activeRequest = null;
    }

    if (_workerGen == gen) {
      _workerGen = null;
    }
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
          '[RPC] rx ${chunk.length} bytes buffered '
          '(${result.pendingState ?? 'no pending frame'})',
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
    _rxParseErrorStreak = 0;
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
      final error = _exceptionFromResponse(frame);
      if (error != null && !_errorCtrl.isClosed) {
        _errorCtrl.add(error);
      }
      if (frame.commandStatus == CommandStatus.ERROR_DECODE) {
        // The firmware lost protobuf framing on its RX side; it closes the
        // RPC session right after sending this (and restarts its BLE stack).
        LogService.log('[RPC] firmware reported ERROR_DECODE; session is dead');
        _scheduleTeardown(
          _sessionGen,
          FlipperTransportError(
            'Firmware reported a protobuf decode error and closed the '
            'RPC session',
          ),
        );
        return;
      }
      _broadcastCtrl.add(frame);
      return;
    }

    final pending = _pendingRpc[commandId];
    if (pending == null) {
      LogService.log('[RPC] rx unmatched frame cmdId=$commandId');
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
    _releaseTxGroup(commandId);
    final error = _exceptionFromResponse(frame);
    if (error != null) {
      if (!_errorCtrl.isClosed) _errorCtrl.add(error);
      pending.completeError(error);
    } else {
      pending.complete();
    }
  }

  void _onFrameParseError(Object error) {
    _rxParseErrorStreak++;
    LogService.log(
      '[RPC] rx parse error ($_rxParseErrorStreak/$_maxRxParseErrorStreak): '
      '$error',
    );
    if (_rxParseErrorStreak < _maxRxParseErrorStreak) return;
    // The inbound stream is desynchronized beyond recovery; close the session
    // with the real reason. Poking the firmware's reset characteristic would
    // restart its whole BLE stack, turning one bad frame into a link drop.
    _scheduleTeardown(
      _sessionGen,
      FlipperTransportError('RPC byte stream desynchronized: $error'),
    );
  }

  Future<void> _ensureCliPrompt() async {
    final transport = _requireTransport();
    final seen = await _waitForTextMatch(
      (text) => text.contains(FlipperClient.cliPrompt),
      timeout: const Duration(seconds: 5),
      trigger: transport.nudgeCli,
    );
    if (!seen) {
      throw TimeoutException('CLI prompt timeout');
    }
  }

  // Listens on textStream until the accumulated text satisfies [test] or
  // [timeout] elapses; a timeout is a result, not an exception. [trigger]
  // runs after the listener is attached; its write errors surface as a
  // non-match.
  Future<bool> _waitForTextMatch(
    bool Function(String text) test, {
    required Duration timeout,
    Future<void> Function()? trigger,
  }) async {
    final matched = Completer<bool>();
    final chunks = StringBuffer();

    final sub = textStream.listen((chunk) {
      if (matched.isCompleted) return;
      chunks.write(chunk);
      if (test(chunks.toString())) {
        matched.complete(true);
      }
    });
    final timer = Timer(timeout, () {
      if (!matched.isCompleted) matched.complete(false);
    });

    if (trigger != null) {
      unawaited(
        trigger().catchError((Object error) {
          LogService.log('[CLI] trigger write failed: $error');
        }),
      );
    }

    final result = await matched.future;
    timer.cancel();
    await sub.cancel();
    return result;
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

  void _setMode(FlipperMode mode, {Object? closeReason}) {
    if (_mode == mode) return;
    _mode = mode;
    _modeCtrl.add(mode);
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: mode,
        device: _connectedDevice,
        connected: mode != FlipperMode.disconnected,
        closeReason: closeReason,
      ),
    );
  }

  // Device info is fetched on demand (awaitName / awaitDeviceInfo), through
  // the normal request queue, at most once per session. The library starts no
  // RPC traffic on its own at connect time.
  void _ensureDeviceInfoFetch() {
    if (_deviceInfoFetched || _deviceInfoFetch != null) return;
    if (_transport == null) return;
    _deviceInfoFetch = _fetchDeviceInfoOnce(_sessionGen);
  }

  Future<void> _fetchDeviceInfoOnce(int gen) async {
    try {
      await deviceInfo(priority: FlipperRequestPriority.foreground);
    } catch (error) {
      LogService.log('[FlipperClient] device info fetch failed: $error');
      if (gen == _sessionGen) _deviceInfoFetch = null;
      return;
    }
    if (gen != _sessionGen) return;
    _deviceInfoFetched = true;
    final snapshot = deviceInfoCache;
    if (!_deviceInfoWatchCtrl.isClosed) {
      _deviceInfoWatchCtrl.add(snapshot);
    }
    if (!_deviceInfoCompleteCtrl.isClosed) {
      _deviceInfoCompleteCtrl.add(snapshot);
    }
  }
}
