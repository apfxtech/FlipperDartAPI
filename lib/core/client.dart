part of '../flipper_client.dart';

class FlipperClient {
  static const String bleServiceUuid = '8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000';
  static const String bleRxUuid = '19ed82ae-ed21-4c9d-4145-228e61fe0000';
  static const String bleTxUuid = '19ed82ae-ed21-4c9d-4145-228e62fe0000';
  static const String cliPrompt = '\r\n\r\n>: ';
  static const String startRpcSession = 'start_rpc_session\r';
  static const int _maxRxParseErrorStreak = 3;
  static const Duration _quickDropWindow = Duration(seconds: 30);
  static const int _maxQuickDropStreak = 2;
  static const Duration _reconnectSettle = Duration(milliseconds: 600);

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
  final Map<String, String> _deviceInfoWatchSnapshot = {};
  final _frameBuffer = _FrameBuffer();
  final _utf8Decoder = const Utf8Decoder(allowMalformed: true);
  Future<void> _lifecycleChain = Future.value();
  int _sessionGen = 0;
  _Transport? _transport;
  StreamSubscription<List<int>>? _transportSub;
  FlipperDevice? _connectedDevice;
  FlipperDevice? _connectingDevice;
  FlipperMode _mode = FlipperMode.disconnected;
  Future<void>? _switchToRpcFuture;
  Future<void>? _deviceInfoFetch;
  bool cliExclusive = false;
  bool _deviceInfoFetched = false;
  int _collectionGen = 0;
  int _watchFreezeCount = 0;
  int _rxParseErrorStreak = 0;

  bool autoReconnect = true;
  final Stopwatch _sessionUptime = Stopwatch();
  int _quickDropStreak = 0;

  Completer<void>? _queueSignal;
  int? _workerGen;
  int _requestSeq = 0;
  _QueuedRequest? _activeRequest;
  int? _txGroupCommandId;

  int _nextCommandId = 1;
  bool _scanning = false;
  _LinkPhase _linkPhase = _LinkPhase.disconnected;
  Completer<void>? _scanPhaseInterrupt;
  static const Duration _scanGraceWindow = Duration(seconds: 5);
  Timer? _scanGraceTimer;
  static const Duration _devicesEmitWindow = Duration(milliseconds: 200);
  Timer? _devicesEmitTimer;
  bool _devicesEmitDirty = false;
  Future<void> _cliChain = Future.value();
  int _storageOpsInFlight = 0;
  final _storageMutationCtrl = StreamController<void>.broadcast();

  static const Set<Main_Content> _heavyStorageContent = {
    Main_Content.storageWriteRequest,
    Main_Content.storageReadRequest,
    Main_Content.storageDeleteRequest,
  };

  static const Set<Main_Content> _mutatingStorageContent = {
    Main_Content.storageWriteRequest,
    Main_Content.storageDeleteRequest,
  };

  Stream<List<FlipperDevice>> get devicesStream => _devicesCtrl.stream;

  Stream<FlipperConnectionState> get connectionStream => _connectionCtrl.stream;

  Stream<FlipperMode> get modeStream => _modeCtrl.stream;

  Stream<List<int>> get rawBytesStream => _rawCtrl.stream;

  Stream<String> get textStream => _textCtrl.stream;

  Stream<Main> get messageStream => _messageCtrl.stream;

  Stream<Main> get broadcastStream => _broadcastCtrl.stream;

  Stream<Main> get notificationStream => _broadcastCtrl.stream;

  Stream<FlipperRpcException> get errorStream => _errorCtrl.stream;
  bool get storageBusy => _storageOpsInFlight > 0;
  Stream<void> get storageMutations => _storageMutationCtrl.stream;
  Stream<void> get usbEvents => _usbPlatform.usbEvents;

  List<FlipperDevice> get devices =>
      List.unmodifiable(_devices.values.toList());

  List<FlipperDevice> listDevices() => devices;

  FlipperDevice? get connectedDevice => _connectedDevice;
  bool get isConnecting => _linkPhase == _LinkPhase.connecting;
  FlipperDevice? get connectingDevice => _connectingDevice;
  FlipperDevice? get activeDevice => _connectedDevice ?? _connectingDevice;

  Map<String, String> get deviceInfoCache => Map.unmodifiable(_deviceInfoCache);

  Map<String, String> get deviceInfoWatchSnapshot =>
      Map.unmodifiable(_deviceInfoWatchSnapshot);

  void _publishDeviceInfoPatch(Map<String, String> patch) {
    if (patch.isEmpty) return;
    _deviceInfoWatchSnapshot.addAll(patch);
    if (!_deviceInfoWatchCtrl.isClosed) _deviceInfoWatchCtrl.add(patch);
  }

  Stream<Map<String, String>> get deviceInfoStream =>
      _deviceInfoCompleteCtrl.stream;

  String? getName() =>
      _deviceInfoCache['hardware_name'] ?? _deviceInfoCache['device_name'];

  Future<String> awaitName() async {
    final cached = getName();
    if (cached != null && cached.isNotEmpty) return cached;

    // Resolves as soon as the name arrives mid-fetch; a failed fetch surfaces
    // its error instead of leaving the caller waiting on a stream that will
    // never emit.
    final fetch = _ensureDeviceInfoFetch();
    final nameArrived = Completer<void>();
    final sub = deviceInfoUpdates.listen((patch) {
      final hasName =
          (patch['hardware_name']?.isNotEmpty ?? false) ||
          (patch['device_name']?.isNotEmpty ?? false);
      if (hasName && !nameArrived.isCompleted) nameArrived.complete();
    });
    try {
      await Future.any([nameArrived.future, fetch]);
    } finally {
      await sub.cancel();
    }

    final name = getName();
    if (name == null || name.isEmpty) {
      throw StateError('Device info does not contain a device name');
    }
    return name;
  }

  Future<Map<String, String>> awaitDeviceInfo() async {
    if (_deviceInfoFetched) return deviceInfoCache;
    await _ensureDeviceInfoFetch();
    return deviceInfoCache;
  }

  FlipperMode get mode => _mode;

  bool get isConnected => _linkPhase == _LinkPhase.connected;

  bool get isScanning => _scanning;

  // Scanning is refused while connecting (the radio is busy establishing the
  // link) and while a BLE session is live; a USB session leaves the BLE radio
  // free.
  bool get _scanBlocked {
    switch (_linkPhase) {
      case _LinkPhase.disconnected:
        return false;
      case _LinkPhase.connecting:
        return true;
      case _LinkPhase.connected:
        return _connectedDevice?.isBle ?? false;
    }
  }

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
    final connected = _connectedDevice;
    if (connected != null) _rememberDevice(connected);
    await _loadUsbDevices();
    _emitDevices(immediate: true);
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
    _scanning = true;

    try {
      if (_scanBlocked) {
        LogService.log(
          '[BLE] scan skipped: a connection is active or in progress',
        );
        return;
      }

      final state = await uble.UniversalBle.getBluetoothAvailabilityState();
      if (state != uble.AvailabilityState.poweredOn) {
        LogService.log('[FlipperClient] BLE adapter state: $state');
        return;
      }

      await _loadKnownBleDevices();

      uble.UniversalBle.onScanResult = (device) {
        final discovered = BleDiscoveredDevice(device);
        if (LogService.enabled) {
          LogService.log(
            '[BLE] scan result id=${discovered.id} name=${discovered.name} '
            'rssi=${discovered.rssi} services=${device.services}',
          );
        }
        _rememberDevice(_fromDiscovered(discovered));
        if (_hasFilteredBleDevice()) _armScanGrace();
      };

      // Single phase scanning every advertising device: Flipper identification
      // is name/service based (includeDevice), so the UI filter can also
      // reveal non-Flipper devices on demand.
      LogService.log('[BLE] scan started');
      await uble.UniversalBle.startScan();
      try {
        final interrupt = _scanPhaseInterrupt = Completer<void>();
        await Future.any([Future.delayed(timeout), interrupt.future]);
        if (identical(_scanPhaseInterrupt, interrupt)) {
          _scanPhaseInterrupt = null;
        }
      } finally {
        _scanGraceTimer?.cancel();
        _scanGraceTimer = null;
        await uble.UniversalBle.stopScan();
        uble.UniversalBle.onScanResult = null;
      }
    } finally {
      _scanning = false;
      _emitDevices(immediate: true);
    }
  }

  Future<void> stopScan() async {
    if (!_scanning) return;
    _interruptScanPhase();
    await uble.UniversalBle.stopScan();
    uble.UniversalBle.onScanResult = null;
    _scanning = false;
    _emitDevices(immediate: true);
  }

  void _armScanGrace() {
    if (_scanGraceTimer != null || _scanPhaseInterrupt == null) return;
    LogService.log(
      '[BLE] Flipper found; scanning '
      '${_scanGraceWindow.inSeconds}s more for additional units',
    );
    _scanGraceTimer = Timer(_scanGraceWindow, _interruptScanPhase);
  }

  void _interruptScanPhase() {
    _scanGraceTimer?.cancel();
    _scanGraceTimer = null;
    final interrupt = _scanPhaseInterrupt;
    _scanPhaseInterrupt = null;
    _fireOnce(interrupt);
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

  Future<void> disconnect() {
    // A connect attempt in flight holds the platform link and sits ahead of
    // this teardown in the lifecycle chain. Abort the platform connect up front
    // so the attempt unwinds now instead of blocking the user's disconnect for
    // the full connect timeout. Harmless when nothing is connecting.
    _abortConnectInFlight();
    return _serialized(() => _teardownLocked('disconnect requested'));
  }

  void _abortConnectInFlight() {
    if (_linkPhase != _LinkPhase.connecting) return;
    if (_connectingDevice?.isBle ?? false) {
      _UniversalBleTransportBase.abortPendingConnect();
    }
  }

  // Appends a lifecycle operation to the chain. The chain never breaks: a
  // failed operation surfaces its error to its own caller only.
  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _lifecycleChain.then((_) => op());
    _lifecycleChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // Recovery for faults reported by callbacks. Bound to the generation that
  // faulted: by the time the chain reaches it, a newer session may already be
  // up and must not be touched. Reconnects in place when allowed, otherwise
  // tears down with the original reason.
  void _scheduleFaultRecovery(int gen, Object reason) {
    // Freeze the uptime now: the recovery op runs later through the chain and
    // must judge the dead session by its actual lifetime, not by how long the
    // recovery sat in the queue.
    if (gen == _sessionGen) _sessionUptime.stop();
    unawaited(
      _serialized(() async {
        if (gen != _sessionGen) return;
        final device = _connectedDevice;
        if (!autoReconnect || device == null || !_mayAutoReconnect()) {
          await _teardownLocked(reason);
          return;
        }
        await _reconnectLocked(device, reason);
      }),
    );
  }

  bool _mayAutoReconnect() {
    // The stopwatch is already stopped at fault time, so isRunning must not
    // gate the healthy-session check.
    if (_sessionUptime.elapsed >= _quickDropWindow) {
      _quickDropStreak = 0;
    }
    if (_quickDropStreak >= _maxQuickDropStreak) {
      // Two short-lived sessions in a row: the environment or device is not
      // ready, stop interfering until the user reconnects manually.
      _quickDropStreak = 0;
      return false;
    }
    _quickDropStreak++;
    return true;
  }

  // In-place reconnect to the same device. Keeps the device identity, the
  // device-info cache and every queued request that never started
  // transmitting; fails only commands whose firmware-side state died with the
  // link. Exactly one connect attempt — on failure the session ends with the
  // original fault reason.
  Future<void> _reconnectLocked(FlipperDevice device, Object reason) async {
    LogService.log(
      '[FlipperClient] link lost: $reason; reconnecting to ${device.name}',
    );
    _sessionGen++;

    final transport = _transport;
    final sub = _transportSub;
    _transport = null;
    // The link is down and about to be re-established; keep scans blocked and
    // isConnected false through the settle + re-open window. _establishLocked
    // re-affirms `connecting` and advances to `connected` on success.
    _linkPhase = _LinkPhase.connecting;
    _transportSub = null;
    _switchToRpcFuture = null;
    _frameBuffer.clear();
    _rxParseErrorStreak = 0;

    _failStartedRequests(
      reason is Exception ? reason : StateError('Disconnected: $reason'),
    );
    _setMode(
      FlipperMode.disconnected,
      closeReason: reason,
      reconnecting: true,
    );
    _signalWorker();

    if (sub != null) await sub.cancel();
    if (transport != null) await transport.close();

    // Settle before re-opening. After a fault the transport is already closed,
    // so close() returns without waiting for the platform disconnect to
    // confirm; re-connecting in the same instant leaves CoreBluetooth still
    // tearing down the old CBPeripheral, which wedges the new attempt (lost
    // write callbacks, then a 20s connect timeout). A brief pause lets the
    // platform release the old link first.
    final settleGen = _sessionGen;
    await Future<void>.delayed(_reconnectSettle);
    if (settleGen != _sessionGen) return;

    try {
      await _establishLocked(device);
    } catch (error) {
      LogService.log('[FlipperClient] reconnect failed: $error');
      await _teardownLocked(reason);
      // The mode is already `disconnected`, so _setMode stayed silent; emit
      // the final (non-reconnecting) state explicitly so listeners leave the
      // "reconnecting" presentation.
      if (!_connectionCtrl.isClosed) {
        _connectionCtrl.add(
          FlipperConnectionState(
            mode: FlipperMode.disconnected,
            device: null,
            connected: false,
            closeReason: reason,
          ),
        );
      }
      return;
    }
    LogService.log('[FlipperClient] reconnected to ${device.name}');
  }

  // True for failures caused by the link dying (as opposed to an RPC-level
  // error from the firmware): these are the ones an automatic reconnect can
  // make whole again.
  bool _isLinkDropError(Object error) {
    if (error is FlipperTransportError) return true;
    if (error is StateError) {
      final message = error.message;
      return message.startsWith('Disconnected') ||
          message.startsWith('Request dropped') ||
          message.contains('Transport closed') ||
          message.contains('No active transport');
    }
    return false;
  }

  // Waits until the client is back in RPC mode over a live transport (e.g.
  // after an automatic reconnect), up to [timeout]. The transport check
  // matters: right after a fault the mode still reads `rpc` for a moment while
  // the recovery operation is queued, and trusting it would burn a retry on
  // the dead session. A timeout is a result, not an exception.
  Future<bool> _waitForRpcSession(Duration timeout) async {
    bool healthy() =>
        _mode == FlipperMode.rpc && (_transport?.isActive ?? false);

    if (healthy()) return true;
    final restored = Completer<bool>();
    final timer = Timer(timeout, () {
      if (!restored.isCompleted) restored.complete(false);
    });
    final modeSub = modeStream.listen((mode) {
      if (mode == FlipperMode.rpc && healthy() && !restored.isCompleted) {
        restored.complete(true);
      }
    });
    // A terminal disconnect (no reconnect in progress) ends the wait early
    // instead of burning the whole timeout.
    final connSub = connectionStream.listen((state) {
      if (!state.connected && !state.reconnecting && !restored.isCompleted) {
        restored.complete(false);
      }
    });
    if (healthy() && !restored.isCompleted) {
      restored.complete(true);
    }
    final result = await restored.future;
    timer.cancel();
    await modeSub.cancel();
    await connSub.cancel();
    return result;
  }

  // Fails commands that already (partially) reached the wire — their
  // firmware-side state died with the link. Requests still waiting in the
  // queue replay transparently on the restored session.
  void _failStartedRequests(Object error) {
    _activeRequest = null;
    final startedIds = <int>[
      for (final entry in _pendingRpc.entries)
        if (entry.value.started) entry.key,
    ];
    for (final id in startedIds) {
      _failPendingById(id, error);
    }
  }

  Future<FlipperDevice> _connectLocked(
    FlipperDevice device, {
    bool autoRpc = true,
  }) async {
    await _teardownLocked('replaced by connect to ${device.name}');
    return _establishLocked(device, autoRpc: autoRpc);
  }

  // Opens a transport and commits the session. Callers are responsible for
  // detaching any previous session first: _connectLocked tears it down fully,
  // _reconnectLocked keeps the queue and the device-info cache alive.
  Future<FlipperDevice> _establishLocked(
    FlipperDevice device, {
    bool autoRpc = true,
  }) async {
    // A running scan competes with the connection for the radio (on macOS a
    // second CBCentralManager halves effective throughput).
    await stopScan();

    final gen = ++_sessionGen;
    // Enter the `connecting` phase for the whole connect window. It returns to
    // `disconnected` on failure/supersession, or advances to `connected` the
    // moment the transport is committed (kept in lockstep with `_transport`).
    _linkPhase = _LinkPhase.connecting;
    _connectingDevice = device;
    // Announce the in-flight attempt so a UI can show it and offer to cancel it
    // before it commits or times out (this phase blocks scanning).
    _emitConnecting(device);
    LogService.log(
      '[FlipperClient] connecting to ${device.name} '
      '(${device.link.name}:${device.id})',
    );
    _Transport? transport;
    try {
      transport = await _openTransport(device);
      await transport.open();
    } catch (error) {
      _linkPhase = _LinkPhase.disconnected;
      _clearConnecting(device);
      LogService.log(
        '[FlipperClient] connect failed '
        'device=${device.name} link=${device.link.name}: $error',
      );
      await transport?.close();
      rethrow;
    }

    if (gen != _sessionGen) {
      _linkPhase = _LinkPhase.disconnected;
      _clearConnecting(device);
      await transport.close();
      throw StateError('Connection attempt superseded');
    }

    _transport = transport;
    _linkPhase = _LinkPhase.connected;
    _connectedDevice = device;
    // Hand off to the committed-session state; the `connected` event below comes
    // from _setMode once the transport's initial mode is applied.
    if (identical(_connectingDevice, device)) _connectingDevice = null;
    _transportSub = transport.bytesStream.listen(
      _onTransportBytes,
      onError: (Object error, StackTrace stackTrace) {
        // Transports report failures via onTransportFault and never put error
        // events on bytesStream; defensive guard against a misbehaving
        // backend.
        LogService.log('[FlipperClient] transport stream error: $error');
        _scheduleFaultRecovery(gen, error);
      },
      onDone: () => _onTransportClosed(transport!),
    );

    _setMode(transport.initialMode);
    _startWorker(gen);
    _sessionUptime
      ..reset()
      ..start();
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
    if (transport == null &&
        _connectedDevice == null &&
        _mode == FlipperMode.disconnected &&
        _requestQueue.isEmpty &&
        _pendingRpc.isEmpty &&
        _deviceInfoCache.isEmpty &&
        _deviceInfoWatchSnapshot.isEmpty) {
      return;
    }
    _sessionUptime
      ..stop()
      ..reset();
    _quickDropStreak = 0;

    final sub = _transportSub;
    _transport = null;
    _linkPhase = _LinkPhase.disconnected;
    _transportSub = null;
    _connectedDevice = null;
    _connectingDevice = null;
    _switchToRpcFuture = null;
    _deviceInfoFetch = null;
    _deviceInfoCache.clear();
    _deviceInfoWatchSnapshot.clear();
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
    _scheduleFaultRecovery(_sessionGen, detailedReason);
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
    // Strict on purpose: a real RPC sender (callRpcFrames / sendRpc switches
    // here) must fail fast when there is no transport instead of enqueuing a
    // request that can only time out. The lenient "already disconnected"
    // handling lives in enterRpcMode(), the mode-restore entry point.
    final transport = _requireTransport();
    if (_mode == FlipperMode.rpc) return;
    if (!transport.supportsCli) {
      if (identical(_transport, transport)) {
        _setMode(FlipperMode.rpc);
        _signalWorker();
      }
      return;
    }

    final promptSeen = await _waitForTextMarker(
      FlipperClient.cliPrompt,
      timeout: const Duration(seconds: 5),
      trigger: transport.nudgeCli,
    );
    LogService.log(
      promptSeen != null
          ? '[RPC] CLI prompt detected'
          : '[RPC] CLI prompt not seen within 5s, continuing',
    );
    if (!identical(_transport, transport)) return;

    final echoed = await _waitForTextMarker(
      'start_rpc_session',
      timeout: const Duration(seconds: 2),
      trigger: () => transport.writeAscii(FlipperClient.startRpcSession),
    );
    LogService.log(
      echoed != null
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

  // Mode-restore entry point (UI lifecycle, e.g. a CLI page's dispose()).
  // Unlike the RPC senders, it is lenient: if the session is already gone there
  // is nothing to restore, so it returns quietly instead of throwing. Callers
  // fire it unawaited, where a thrown "No active transport" would otherwise
  // surface as an unhandled exception and crash the frame.
  Future<void> enterRpcMode() {
    if (_transport == null) return Future.value();
    return switchToRpcMode();
  }

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

  // Serialized through _cliChain: concurrent calls would interleave their
  // writes on the shared text stream and corrupt each other's output.
  Future<String> executeCli(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final result = _cliChain.then(
      (_) => _executeCliInner(command, timeout: timeout),
    );
    _cliChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _executeCliInner(
    String command, {
    required Duration timeout,
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
    final text = await _waitForTextMarker(
      FlipperClient.cliPrompt,
      timeout: timeout,
      trigger: () async {
        await transport.writeAscii('\r');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await transport.writeAscii('$command\r');
      },
    );
    if (text == null) {
      throw TimeoutException('CLI command timeout: $command');
    }
    return _trimCliResult(text, command);
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

  // Already-bonded / system-connected BLE devices: an instant platform lookup,
  // no radio scan. Lets callers reconnect to a remembered device without
  // paying the full scan timeout.
  Future<List<FlipperDevice>> refreshBleKnown() async {
    await _loadKnownBleDevices();
    _emitDevices(immediate: true);
    return devices;
  }

  Future<void> _loadKnownBleDevices() async {
    for (final device in await _blePlatform.loadKnownDevices()) {
      _rememberDevice(_fromDiscovered(device));
    }
  }

  Future<List<FlipperDevice>> refreshUsbOnly() async {
    final usbKeyPrefix = '${FlipperLink.usb.name}:';
    final connected = _connectedDevice;
    _devices.removeWhere(
      (key, device) =>
          key.startsWith(usbKeyPrefix) && !identical(device, connected),
    );
    await _loadUsbDevices();
    _emitDevices(immediate: true);
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
    Duration sendTimeout = const Duration(seconds: 30),
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    if (message.commandId == 0) {
      message.commandId = nextCommandId();
    }
    final sent = Completer<void>();
    final queued = _QueuedRequest(
      frame: message,
      priority: priority,
      seq: _requestSeq++,
      onSent: () {
        if (!sent.isCompleted) sent.complete();
      },
      onError: (error) {
        if (!sent.isCompleted) sent.completeError(error);
      },
    );
    _enqueueRequest(queued);
    // A hung transport write must surface as an error, not an infinite await.
    final timer = Timer(sendTimeout, () {
      if (sent.isCompleted) return;
      _requestQueue.remove(queued);
      queued.fail(
        TimeoutException(
          'RPC send timeout after ${sendTimeout.inSeconds}s '
          'for ${queued.describe()}',
        ),
      );
    });
    try {
      await sent.future;
    } finally {
      timer.cancel();
    }
  }

  Future<List<Main>> callRpcFrames(
    Main request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
    void Function(Main frame)? onFrame,
    bool retainFrames = true,
    bool interleavable = false,
  }) async {
    if (_mode != FlipperMode.rpc) {
      await switchToRpcMode();
    }
    final commandId = request.commandId == 0
        ? nextCommandId()
        : request.commandId;
    request.commandId = commandId;

    final pending = _PendingRpc(commandId)
      ..onFrame = onFrame
      ..retainFrames = retainFrames;
    _pendingRpc[commandId] = pending;

    _enqueueRequest(
      _QueuedRequest(
        frame: request,
        priority: priority,
        seq: _requestSeq++,
        interleavable: interleavable,
        onSent: () {
          pending.started = true;
          pending.rearmTimeout();
        },
        onError: (error) => _failPendingById(commandId, error),
      ),
    );
    // Armed at enqueue, not at TX: a write that never completes (hung
    // platform stack) must not leave the caller waiting forever.
    pending.armTimeout(timeout, () {
      _onRpcTimeout(
        commandId,
        'RPC timeout for commandId=$commandId '
        'after ${timeout.inSeconds}s started=${pending.started} '
        'framesReceived=${pending.frameCount}',
      );
    });

    final content = request.whichContent();
    final trackStorage = _heavyStorageContent.contains(content);
    if (trackStorage) _storageOpsInFlight++;
    try {
      return await pending.future;
    } finally {
      _pendingRpc.remove(commandId);
      _releaseTxGroup(commandId);
      pending.cancelTimeout();
      if (trackStorage) {
        _storageOpsInFlight--;
        _notifyStorageMutation(content);
      }
    }
  }

  void _notifyStorageMutation(Main_Content content) {
    if (!_mutatingStorageContent.contains(content)) return;
    if (_storageMutationCtrl.isClosed) return;
    _storageMutationCtrl.add(null);
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
    // The command's content becomes known with the first frame the body
    // sends; storage tracking starts there and ends with the call.
    var trackedContent = Main_Content.notSet;
    var trackingStorage = false;

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
          'started=${pending.started} '
          'queued=${_requestQueue.length} pending=${_pendingRpc.keys.toList()}',
        );
      });
    }

    Future<void> sendFrame(Main frame) {
      frame.commandId = commandId;
      if (trackedContent == Main_Content.notSet) {
        trackedContent = frame.whichContent();
        if (_heavyStorageContent.contains(trackedContent)) {
          trackingStorage = true;
          _storageOpsInFlight++;
        }
      }
      final sent = Completer<void>();
      final isFinal = !frame.hasNext;
      _enqueueRequest(
        _QueuedRequest(
          frame: frame,
          priority: priority,
          seq: _requestSeq++,
          onSent: () {
            if (isFinal) finalFrameSent = true;
            pending.started = true;
            armOrRearmTimeout();
            if (!sent.isCompleted) sent.complete();
          },
          onError: (error) {
            if (!sent.isCompleted) sent.completeError(error);
          },
        ),
      );
      // Armed at enqueue (see callRpcFrames): a frame stuck before TX must
      // still time out instead of hanging the upload body forever.
      armOrRearmTimeout();
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
      if (trackingStorage) {
        _storageOpsInFlight--;
        _notifyStorageMutation(trackedContent);
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
    _fireOnce(signal);
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
        (r) => r.frame.commandId == lockedId || r.interleavable,
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
    return _requestQueue.any(
      (r) => r.frame.commandId == lockedId || r.interleavable,
    );
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
      if (LogService.enabled) {
        LogService.log(
          '[RPC] tx ok ${request.describe()} bytes=${encoded.length}',
        );
      }

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
        if (LogService.enabled) {
          LogService.log(
            '[RPC] rx ${chunk.length} bytes buffered '
            '(${result.pendingState ?? 'no pending frame'})',
          );
        }
        return;
      }
      for (final frame in result.frames) {
        // A throwing listener (messageStream subscriber, select() transform)
        // must not abort the loop: the remaining frames of this chunk would
        // be lost and their commands would time out.
        try {
          _routeFrame(frame);
        } catch (error) {
          LogService.log('[RPC] frame routing threw: $error');
        }
      }
      if (LogService.enabled && result.pendingState != null) {
        LogService.log(
          '[RPC] parsed ${result.frames.length} frame(s), residual '
          '${result.pendingState}',
        );
      }
      return;
    }

    final text = _utf8Decoder.convert(chunk);
    if (LogService.enabled) {
      LogService.log(
        '[CLI] rx: ${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}',
      );
    }
    _textCtrl.add(text);
  }

  void _routeFrame(Main frame) {
    // Random bytes occasionally survive Main.fromBuffer (protobuf tolerates
    // unknown fields), so a parsed frame alone does not prove the stream is
    // healthy — a desynchronized session could otherwise alternate between
    // parse errors and accidental "successes" forever. Only frames that match
    // an in-flight command or carry recognizable content reset the streak.
    if (frame.whichContent() != Main_Content.notSet ||
        _pendingRpc.containsKey(frame.commandId)) {
      _rxParseErrorStreak = 0;
    }
    _messageCtrl.add(frame);

    if (frame.hasSystemDeviceInfoResponse()) {
      final info = frame.systemDeviceInfoResponse;
      final key = info.key.trim();
      final value = info.value.trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        _deviceInfoCache[key] = value;
        _publishDeviceInfoPatch({key: value});
      }
    }

    final commandId = frame.commandId;
    if (commandId == 0) {
      if (LogService.enabled) {
        // Broadcasts arrive at screen-streaming frame rate; keep this cheap.
        LogService.log(
          '[RPC] rx broadcast content=${frame.whichContent().name}',
        );
      }
      final error = _exceptionFromResponse(frame);
      if (error != null && !_errorCtrl.isClosed) {
        _errorCtrl.add(error);
      }
      if (frame.commandStatus == CommandStatus.ERROR_DECODE) {
        // The firmware lost protobuf framing on its RX side; it closes the
        // RPC session right after sending this (and restarts its BLE stack).
        LogService.log('[RPC] firmware reported ERROR_DECODE; session is dead');
        _scheduleFaultRecovery(
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
      if (frame.commandStatus ==
          CommandStatus.ERROR_CONTINUOUS_COMMAND_INTERRUPTED) {
        // Expected aftermath of a timed-out multi-frame command: the firmware
        // closes the abandoned write stream when the next command arrives and
        // reports it against the old (already failed) commandId.
        LogService.log(
          '[RPC] firmware closed interrupted stream cmdId=$commandId '
          '(command already timed out locally)',
        );
        return;
      }
      LogService.log('[RPC] rx unmatched frame cmdId=$commandId');
      return;
    }

    if (LogService.enabled) {
      LogService.log(
        '[RPC] rx frame cmdId=$commandId hasNext=${frame.hasNext} '
        'status=${frame.commandStatus.name} '
        'content=${frame.whichContent().name} '
        'frameN=${pending.frameCount + 1}',
      );
    }
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
    _scheduleFaultRecovery(
      _sessionGen,
      FlipperTransportError('RPC byte stream desynchronized: $error'),
    );
  }

  Future<void> _ensureCliPrompt() async {
    final transport = _requireTransport();
    final seen = await _waitForTextMarker(
      FlipperClient.cliPrompt,
      timeout: const Duration(seconds: 5),
      trigger: transport.nudgeCli,
    );
    if (seen == null) {
      throw TimeoutException('CLI prompt timeout');
    }
  }

  // Listens on textStream until [marker] appears in the accumulated text or
  // [timeout] elapses. Returns the full accumulated text on match, null on
  // timeout — a timeout is a result, not an exception. [trigger] runs after
  // the listener is attached; its write errors surface as a non-match.
  //
  // The marker is searched in a rolling tail window (last chunk plus
  // marker-1 carry-over chars), so cost stays O(chunk) per event instead of
  // re-scanning the whole accumulated text — large CLI outputs used to make
  // this quadratic.
  Future<String?> _waitForTextMarker(
    String marker, {
    required Duration timeout,
    Future<void> Function()? trigger,
  }) async {
    final matched = Completer<String?>();
    final chunks = StringBuffer();
    final carry = marker.length - 1;
    var window = '';

    final sub = textStream.listen((chunk) {
      if (matched.isCompleted) return;
      chunks.write(chunk);
      window = window + chunk;
      if (window.contains(marker)) {
        matched.complete(chunks.toString());
        return;
      }
      if (window.length > carry) {
        window = window.substring(window.length - carry);
      }
    });
    final timer = Timer(timeout, () {
      if (!matched.isCompleted) matched.complete(null);
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

  // Throttled: at most one event per window, plus a trailing event so the
  // final state always reaches listeners. `immediate` flushes right away
  // (scan finished, explicit refresh).
  void _emitDevices({bool immediate = false}) {
    if (immediate) {
      _devicesEmitTimer?.cancel();
      _devicesEmitTimer = null;
      _devicesEmitDirty = false;
      _emitDevicesNow();
      return;
    }
    if (_devicesEmitTimer != null) {
      _devicesEmitDirty = true;
      return;
    }
    _emitDevicesNow();
    _devicesEmitTimer = Timer(_devicesEmitWindow, () {
      _devicesEmitTimer = null;
      if (_devicesEmitDirty) {
        _devicesEmitDirty = false;
        _emitDevices();
      }
    });
  }

  void _emitDevicesNow() {
    if (_devicesCtrl.isClosed) return;
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
    _devicesEmitTimer?.cancel();
    _devicesEmitTimer = null;
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
    await _storageMutationCtrl.close();
  }

  // Emits the in-flight connect as a connection event. Goes straight to the
  // controller rather than through _setMode: the mode stays `disconnected`
  // until the transport commits, so there is no mode transition to ride on.
  void _emitConnecting(FlipperDevice device) {
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: _mode,
        device: device,
        connected: false,
        connecting: true,
      ),
    );
  }

  // Clears the in-flight attempt (only if [device] still owns it — a newer
  // attempt may have replaced it) and announces the terminal disconnect, which
  // _setMode would swallow because the mode never left `disconnected`.
  void _clearConnecting(FlipperDevice device) {
    if (!identical(_connectingDevice, device)) return;
    _connectingDevice = null;
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: _mode,
        device: null,
        connected: false,
      ),
    );
  }

  void _setMode(
    FlipperMode mode, {
    Object? closeReason,
    bool reconnecting = false,
  }) {
    if (_mode == mode) return;
    _mode = mode;
    _modeCtrl.add(mode);
    _connectionCtrl.add(
      FlipperConnectionState(
        mode: mode,
        device: _connectedDevice,
        connected: mode != FlipperMode.disconnected,
        closeReason: closeReason,
        reconnecting: reconnecting,
      ),
    );
  }

  // Device info is fetched on demand (awaitName / awaitDeviceInfo), through
  // the normal request queue, at most once per session. The library starts no
  // RPC traffic on its own at connect time. The returned future errors when
  // the fetch fails (no transport, RPC error, link drop) so callers fail fast
  // instead of waiting for a snapshot that will never arrive; a later call
  // starts a fresh attempt.
  Future<void> _ensureDeviceInfoFetch() {
    final existing = _deviceInfoFetch;
    if (existing != null) return existing;
    if (_deviceInfoFetched) return Future.value();
    if (_transport == null) {
      return Future.error(
        StateError('Cannot fetch device info: no active transport'),
      );
    }
    late final Future<void> fetch;
    fetch = _fetchDeviceInfoOnce().whenComplete(() {
      if (identical(_deviceInfoFetch, fetch)) _deviceInfoFetch = null;
    });
    _deviceInfoFetch = fetch;
    return fetch;
  }

  Future<void> _fetchDeviceInfoOnce() async {
    // Device identity, not session generation: the cache stays valid across an
    // automatic reconnect to the same device, but never leaks to another one.
    final device = _connectedDevice;
    try {
      await deviceInfo(priority: FlipperRequestPriority.foreground);
    } catch (error) {
      LogService.log('[FlipperClient] device info fetch failed: $error');
      rethrow;
    }
    if (!identical(_connectedDevice, device)) {
      throw StateError('Device info fetch outlived its session');
    }
    _deviceInfoFetched = true;
    final snapshot = deviceInfoCache;
    _publishDeviceInfoPatch(snapshot);
    if (!_deviceInfoCompleteCtrl.isClosed) {
      _deviceInfoCompleteCtrl.add(snapshot);
    }
  }
}

// Coarse client-side connection lifecycle. `connecting` covers the whole
// connect window (transport not yet committed); `connected` mirrors
// `_transport != null`. See FlipperClient._linkPhase.
enum _LinkPhase { disconnected, connecting, connected }
