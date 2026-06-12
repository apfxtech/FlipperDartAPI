part of '../flipper_client.dart';

class _BleService {
  final String uuid;
  final List<_BleChar> characteristics;
  _BleService(this.uuid, this.characteristics);
}

class _BleChar {
  final String uuid;
  final bool canWrite;
  final bool canWriteNoRsp;
  final bool canNotify;
  final bool canIndicate;
  _BleChar(
    this.uuid, {
    required this.canWrite,
    required this.canWriteNoRsp,
    required this.canNotify,
    required this.canIndicate,
  });
}

enum _BleConnState { connected, connecting, disconnected }

abstract class _BleOps {
  set onConnectionChange(
    void Function(String deviceId, bool isConnected, String? error)? cb,
  );

  set onValueChange(
    void Function(String deviceId, String charId, Uint8List value, int? mtu)?
    cb,
  );

  Future<void> connect(String deviceId);
  Future<int> requestMtu(String deviceId, int mtu);
  Future<List<_BleService>> discoverServices(String deviceId);
  Future<void> subscribeNotifications(
    String deviceId,
    String svcId,
    String charId,
  );
  Future<void> subscribeIndications(
    String deviceId,
    String svcId,
    String charId,
  );
  Future<Uint8List> read(String deviceId, String svcId, String charId);
  Future<void> write(
    String deviceId,
    String svcId,
    String charId,
    Uint8List data, {
    bool withoutResponse = false,
  });
  Future<void> disconnect(String deviceId);
  Future<_BleConnState?> getConnectionState(String deviceId);
}

class _UniversalBleOps implements _BleOps {
  @override
  set onConnectionChange(void Function(String, bool, String?)? cb) {
    uble.UniversalBle.onConnectionChange = cb == null
        ? null
        : (did, conn, err) => cb(did, conn, err?.toString());
  }

  @override
  set onValueChange(void Function(String, String, Uint8List, int?)? cb) {
    uble.UniversalBle.onValueChange = cb;
  }

  @override
  Future<void> connect(String deviceId) => uble.UniversalBle.connect(deviceId);

  @override
  Future<int> requestMtu(String deviceId, int mtu) =>
      uble.UniversalBle.requestMtu(deviceId, mtu);

  @override
  Future<List<_BleService>> discoverServices(String deviceId) async {
    final svcs = await uble.UniversalBle.discoverServices(deviceId);
    return svcs.map((s) {
      final chars = s.characteristics.map((c) {
        return _BleChar(
          c.uuid,
          canWrite: c.properties.contains(uble.CharacteristicProperty.write),
          canWriteNoRsp: c.properties.contains(
            uble.CharacteristicProperty.writeWithoutResponse,
          ),
          canNotify: c.properties.contains(uble.CharacteristicProperty.notify),
          canIndicate: c.properties.contains(
            uble.CharacteristicProperty.indicate,
          ),
        );
      }).toList();
      return _BleService(s.uuid, chars);
    }).toList();
  }

  @override
  Future<void> subscribeNotifications(
    String deviceId,
    String svcId,
    String charId,
  ) => uble.UniversalBle.subscribeNotifications(deviceId, svcId, charId);

  @override
  Future<void> subscribeIndications(
    String deviceId,
    String svcId,
    String charId,
  ) => uble.UniversalBle.subscribeIndications(deviceId, svcId, charId);

  @override
  Future<Uint8List> read(String deviceId, String svcId, String charId) =>
      uble.UniversalBle.read(deviceId, svcId, charId);

  @override
  Future<void> write(
    String deviceId,
    String svcId,
    String charId,
    Uint8List data, {
    bool withoutResponse = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final mode = withoutResponse ? 'withoutResponse' : 'withResponse';
    try {
      await uble.UniversalBle.write(
        deviceId,
        svcId,
        charId,
        data,
        withoutResponse: withoutResponse,
      );
      LogService.log(
        '[UniversalBle] write done len=${data.length} mode=$mode '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error) {
      LogService.log(
        '[UniversalBle] write failed len=${data.length} mode=$mode '
        'elapsedMs=${stopwatch.elapsedMilliseconds} error=$error',
      );
      rethrow;
    }
  }

  @override
  Future<void> disconnect(String deviceId) =>
      uble.UniversalBle.disconnect(deviceId);

  @override
  Future<_BleConnState?> getConnectionState(String deviceId) async {
    try {
      final s = await uble.UniversalBle.getConnectionState(deviceId);
      return switch (s) {
        uble.BleConnectionState.connected => _BleConnState.connected,
        uble.BleConnectionState.connecting => _BleConnState.connecting,
        _ => _BleConnState.disconnected,
      };
    } catch (_) {
      return null;
    }
  }
}

abstract class _BlePlatform {
  Future<void> requestPermissions();

  // Already-bonded / system-known devices: an instant lookup (not a scan),
  // queried once at the start of every scan to surface devices that are
  // connected but not currently advertising.
  Future<List<BleDiscoveredDevice>> loadKnownDevices();

  bool includeDevice(BleDiscoveredDevice device);

  Future<_Transport> openTransport(BleDiscoveredDevice device);
}

abstract class _UniversalBlePlatformBase implements _BlePlatform {
  const _UniversalBlePlatformBase();

  // Flipper Zero's BLE MAC OUI. Present on platforms that expose the MAC
  // (Android / Linux / Windows); iOS / macOS expose an opaque UUID instead and
  // fall back to the advertised name.
  static const List<String> _flipperMacPrefixes = ['80E127', '80E126'];

  @override
  Future<List<BleDiscoveredDevice>> loadKnownDevices() async {
    return const <BleDiscoveredDevice>[];
  }

  @override
  bool includeDevice(BleDiscoveredDevice device) {
    if (_advertisesFlipperService(device)) return true;

    final id = device.id.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (_flipperMacPrefixes.any(id.startsWith)) return true;

    final name = device.name.toLowerCase();
    return name.contains('flipper') || name.contains('flip_');
  }

  bool _advertisesFlipperService(BleDiscoveredDevice device) {
    bool hasFlipper(Iterable<String> uuids) => uuids
        .map((uuid) => uuid.toLowerCase())
        .contains(FlipperClient.bleServiceUuid);
    return hasFlipper(device.device.services) ||
        hasFlipper(device.device.serviceData.keys);
  }
}

// Firmware contract (serial_service.c, bt.c, rpc.c in unleashed-firmware):
// - Flow control: the firmware grants RPC_BUFFER_SIZE (1024) bytes of credit,
//   counts every byte written to RX against it, and notifies a fresh full
//   credit only after the counter hit zero AND its RPC thread drained the
//   buffer. Sending past the credit drops bytes (1 s feed timeout) and breaks
//   the protobuf varint framing permanently.
// - rpcStatus is 1 only while the firmware RPC session is open. The session
//   opens on the GAP connected event (after pairing), which is later than our
//   GATT subscriptions; bytes written earlier are silently discarded. After a
//   decode error the firmware sends ERROR_DECODE and restarts its whole BLE
//   stack.
// - Writing 0 to rpcStatus restarts the firmware BLE stack. Never write it.
abstract class _UniversalBleTransportBase extends _Transport {
  static const String overflowCharUuid = '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const String rpcStatusCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e64fe0000';
  static const int _bleChunkSize = 512;
  static const int _minBleMtuSize = 20;
  // DO NOT CHANGE: 160 is the empirically stable ATT write payload for this
  // firmware. Raising it toward the 411-byte ATT_MTU ceiling makes link drops
  // far more frequent.
  static const int _maxBleMtuSize = 160;
  // Platform connect attempts never time out on their own (CoreBluetooth keeps
  // them pending forever); bonded-link re-encryption also happens inside this
  // step.
  static const Duration _connectTimeout = Duration(seconds: 20);
  // TX stall watchdog: with data pending, the firmware must grant credit /
  // activate the session well within this window; silence means the session
  // is dead and every queued task must settle instead of hanging.
  static const Duration _stallPoll = Duration(seconds: 5);
  static const int _stallPollLimit = 6;

  // Exactly one transport may own the platform link at a time. A stale
  // attempt's timeout or close must never disconnect a newer connection.
  static int _connectAttemptGen = 0;
  static _UniversalBleTransportBase? _connectionOwner;
  static _UniversalBleTransportBase? _activeTransport;

  final BleDiscoveredDevice _device;
  final _BleOps _ops;

  late final String _txSvcId;
  late final String _txCharId;
  late final String _rxSvcId;
  late final String _rxCharId;
  late final bool _txWithResponse;
  late final bool _rxUsesIndicate;
  late int _bleMtuSize;

  String? _overflowSvcId;
  String? _overflowCharId;
  String? _rpcStatusSvcId;
  String? _rpcStatusCharId;

  late String _rxCharIdLower;
  late String _overflowCharIdLower;
  late String _rpcStatusCharIdLower;

  final List<_BlePendingSend> _txQueue = [];
  Completer<void>? _txDataSignal;

  // Flow-control credit mirror. _budgetGen detects that a fresh authoritative
  // credit notification arrived while a write was in flight.
  int _budget = 0;
  int _budgetGen = 0;
  Completer<void>? _budgetSignal;

  // Firmware RPC session state mirrored from the rpcStatus characteristic.
  bool _rpcSessionActive = false;
  bool _rpcStatusAvailable = false;
  Completer<void>? _rpcActiveSignal;

  Completer<void>? _disconnectSignal;
  bool _senderRunning = false;
  _BleLinkState _link = _BleLinkState.disconnected;
  bool _platformConnectionEstablished = false;

  _UniversalBleTransportBase(this._device, this._ops);

  // Platform hook that runs after all subscriptions are in place
  // (macOS: connection-parameter settle).
  Future<void> _openExtra() async {}

  Future<void> _configure() async {
    final deviceId = _device.device.deviceId;
    final connectAttempt = ++_connectAttemptGen;
    _connectionOwner = this;
    var connectTimedOut = false;
    await _ops.connect(deviceId).timeout(
      _connectTimeout,
      onTimeout: () {
        connectTimedOut = true;
      },
    );
    if (connectTimedOut) {
      if (connectAttempt == _connectAttemptGen &&
          identical(_connectionOwner, this)) {
        unawaited(
          _ops.disconnect(deviceId).catchError((Object e) {
            LogService.log('[BLE] connect-timeout cancel failed: $e');
          }),
        );
      }
      throw FlipperTransportError(
        'BLE connect timeout after ${_connectTimeout.inSeconds}s '
        '(device unreachable, or its bond/encryption is stalled — '
        'try forgetting the pairing on both sides)',
      );
    }
    _platformConnectionEstablished = true;
    if (connectAttempt != _connectAttemptGen) {
      // A newer attempt owns the platform link now; do not touch it.
      throw StateError('BLE connection attempt superseded');
    }
    try {
      await _configureConnected(deviceId);
    } catch (_) {
      // The factory never returns this transport, so nobody will close() it:
      // the platform link must be released here or it leaks as a ghost
      // connection.
      if (identical(_connectionOwner, this)) {
        _connectionOwner = null;
        _platformConnectionEstablished = false;
        unawaited(
          _ops.disconnect(deviceId).catchError((Object e) {
            LogService.log('[BLE] cleanup disconnect failed: $e');
          }),
        );
      }
      rethrow;
    }
  }

  Future<void> _configureConnected(String deviceId) async {
    int negotiatedMtu = 23;
    try {
      negotiatedMtu = await _ops.requestMtu(deviceId, 517);
    } catch (e) {
      LogService.log(
        '[BLE] requestMtu failed: $e (using default $negotiatedMtu)',
      );
    }

    final services = await _ops.discoverServices(deviceId);
    String? txSvc;
    String? txChar;
    String? rxSvc;
    String? rxChar;
    String? overflowSvc;
    String? overflowChar;
    String? rpcStatusSvc;
    String? rpcStatusChar;
    var txWithResponse = true;
    var rxUsesIndicate = false;

    for (final service in services) {
      final sid = service.uuid.toLowerCase();
      if (sid != FlipperClient.bleServiceUuid) continue;
      for (final char in service.characteristics) {
        final cid = char.uuid.toLowerCase();
        if (cid == FlipperClient.bleTxUuid) {
          txSvc = service.uuid;
          txChar = char.uuid;
          // Write WITH response: each ATT write is acknowledged by the
          // peripheral before the next one goes out. Empirically stable on
          // this firmware; do not switch to write-without-response.
          txWithResponse = char.canWrite;
        }
        if (cid == FlipperClient.bleRxUuid) {
          rxSvc = service.uuid;
          rxChar = char.uuid;
          rxUsesIndicate = char.canIndicate;
        }
        if (cid == overflowCharUuid) {
          overflowSvc = service.uuid;
          overflowChar = char.uuid;
        }
        if (cid == rpcStatusCharUuid) {
          rpcStatusSvc = service.uuid;
          rpcStatusChar = char.uuid;
        }
      }
    }

    final missing = <String>[
      if (txSvc == null || txChar == null) 'tx(${FlipperClient.bleTxUuid})',
      if (rxSvc == null || rxChar == null) 'rx(${FlipperClient.bleRxUuid})',
      if (overflowSvc == null || overflowChar == null)
        'overflow($overflowCharUuid)',
      if (rpcStatusSvc == null || rpcStatusChar == null)
        'rpcStatus($rpcStatusCharUuid)',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing Flipper BLE characteristics: ${missing.join(', ')}',
      );
    }

    _txSvcId = txSvc!;
    _txCharId = txChar!;
    _rxSvcId = rxSvc!;
    _rxCharId = rxChar!;
    _txWithResponse = txWithResponse;
    _rxUsesIndicate = rxUsesIndicate;
    _bleMtuSize = (negotiatedMtu - 3).clamp(_minBleMtuSize, _maxBleMtuSize);
    _overflowSvcId = overflowSvc;
    _overflowCharId = overflowChar;
    _rpcStatusSvcId = rpcStatusSvc;
    _rpcStatusCharId = rpcStatusChar;
    _rxCharIdLower = _rxCharId.toLowerCase();
    _overflowCharIdLower = _overflowCharId!.toLowerCase();
    _rpcStatusCharIdLower = _rpcStatusCharId!.toLowerCase();
    LogService.log(
      '[BLE] configured: negotiatedMtu=$negotiatedMtu mtu=$_bleMtuSize '
      'txWithResponse=$_txWithResponse',
    );
  }

  @override
  bool get supportsCli => false;

  @override
  FlipperMode get initialMode => FlipperMode.rpc;

  @override
  Future<void> open() async {
    _activeTransport = this;
    _ops.onConnectionChange = _onConnectionChange;
    _ops.onValueChange = _onValueChange;
    _link = _BleLinkState.connected;

    final deviceId = _device.device.deviceId;
    if (_rxUsesIndicate) {
      await _ops.subscribeIndications(deviceId, _rxSvcId, _rxCharId);
    } else {
      await _ops.subscribeNotifications(deviceId, _rxSvcId, _rxCharId);
    }

    await _ops.subscribeNotifications(
      deviceId,
      _overflowSvcId!,
      _overflowCharId!,
    );
    final initialBudget = await _ops.read(
      deviceId,
      _overflowSvcId!,
      _overflowCharId!,
    );
    _applyOverflowValue(initialBudget);

    await _subscribeRpcStatus(deviceId);
    await _openExtra();
    _startSender();
    LogService.log('[BLE] transport open (rpcSession=$_rpcSessionActive)');
  }

  Future<void> _subscribeRpcStatus(String deviceId) async {
    final svc = _rpcStatusSvcId;
    final chr = _rpcStatusCharId;
    if (svc == null || chr == null) return;
    try {
      await _ops
          .subscribeNotifications(deviceId, svc, chr)
          .timeout(const Duration(seconds: 4));
      final initial = await _ops.read(deviceId, svc, chr);
      _rpcStatusAvailable = true;
      _applyRpcStatusValue(initial);
    } catch (e) {
      // Without rpcStatus, session readiness cannot be observed; fall back to
      // ungated TX instead of holding the queue forever.
      _rpcStatusAvailable = false;
      LogService.log('[BLE] rpcStatus unavailable, TX gating disabled: $e');
    }
  }

  void _onConnectionChange(String deviceId, bool isConnected, String? error) {
    if (deviceId != _device.device.deviceId) return;
    if (isConnected) return;
    final wasDisconnecting = _link == _BleLinkState.disconnecting;
    final platformError = error?.trim();
    final reason = platformError == null || platformError.isEmpty
        ? 'backend connectionChange disconnected without platform reason '
              '(likely supervision timeout / peer reset / out of range)'
        : 'backend connectionChange disconnected: $platformError';
    final diagnostics =
        'link=${_link.name} budget=$_budget txPending=${_txQueue.length} '
        'rpcSession=${_rpcStatusAvailable ? _rpcSessionActive : 'unknown'}';
    _markBleDisconnected();
    if (!wasDisconnecting) {
      onTransportFault(FlipperTransportError('BLE $reason ($diagnostics)'));
    }
  }

  void _onValueChange(
    String deviceId,
    String charId,
    Uint8List value,
    int? mtu,
  ) {
    if (deviceId != _device.device.deviceId) return;
    final lower = charId.toLowerCase();
    if (lower == _rxCharIdLower) {
      addBytes(value);
      return;
    }
    if (lower == _overflowCharIdLower) {
      _applyOverflowValue(value);
      return;
    }
    if (lower == _rpcStatusCharIdLower) {
      _applyRpcStatusValue(value);
    }
  }

  void _applyOverflowValue(List<int> value) {
    final bytes = value is Uint8List ? value : Uint8List.fromList(value);
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    // serial_service.c stores the credit big-endian (REVERSE_BYTES_U32).
    int remaining;
    if (bytes.length >= 4) {
      remaining = view.getUint32(0, Endian.big);
    } else if (bytes.length >= 2) {
      remaining = view.getUint16(0, Endian.big);
    } else {
      LogService.log('[BLE] overflow value too short (${bytes.length} bytes)');
      return;
    }
    _budget = remaining;
    _budgetGen += 1;
    LogService.log('[BLE] credit granted: $remaining bytes (gen $_budgetGen)');
    final signal = _budgetSignal;
    _budgetSignal = null;
    _fireSignal(signal);
  }

  void _applyRpcStatusValue(List<int> value) {
    final active = value.any((b) => b != 0);
    if (active == _rpcSessionActive) return;
    _rpcSessionActive = active;
    LogService.log('[BLE] rpcSession=${active ? 'active' : 'inactive'}');
    if (active) {
      final signal = _rpcActiveSignal;
      _rpcActiveSignal = null;
      _fireSignal(signal);
      return;
    }
    if (!isActive || _link != _BleLinkState.connected) return;
    // The firmware deactivates the session right before tearing the link down
    // (e.g. after a decode error); report the real cause now.
    onTransportFault(
      FlipperTransportError('Flipper closed the RPC session (rpcStatus=0)'),
    );
  }

  @override
  Future<void> rawWrite(Uint8List bytes) {
    if (!isActive) {
      return Future.error(StateError('BLE transport closed'));
    }
    if (bytes.isEmpty) return Future.value();

    // Resolves only after the complete frame crossed every overflow-credit
    // boundary, keeping the RPC worker blocked until then.
    final pending = _BlePendingSend(bytes);
    _txQueue.add(pending);
    final signal = _txDataSignal;
    _txDataSignal = null;
    _fireSignal(signal);
    _startSender();
    return pending.future;
  }

  void _startSender() {
    if (_senderRunning) return;
    _senderRunning = true;
    unawaited(_runSender());
  }

  Future<void> _runSender() async {
    var sessionPolls = 0;
    var budgetPolls = 0;
    while (isActive) {
      if (_txQueue.isEmpty) {
        sessionPolls = 0;
        budgetPolls = 0;
        final signal = _txDataSignal = Completer<void>();
        await signal.future;
        continue;
      }

      if (_rpcStatusAvailable && !_rpcSessionActive) {
        final signal = _rpcActiveSignal = Completer<void>();
        if (await _awaitSignal(signal, _stallPoll)) {
          sessionPolls = 0;
          continue;
        }
        sessionPolls++;
        if (sessionPolls == 1) {
          LogService.log('[BLE] TX held: firmware RPC session not active');
        }
        if (sessionPolls >= _stallPollLimit && isActive) {
          onTransportFault(
            FlipperTransportError(
              'Firmware RPC session did not become active within '
              '${_stallPoll.inSeconds * _stallPollLimit}s with TX pending',
            ),
          );
          break;
        }
        continue;
      }
      sessionPolls = 0;

      if (_budget <= 0) {
        final signal = _budgetSignal = Completer<void>();
        if (await _awaitSignal(signal, _stallPoll)) {
          budgetPolls = 0;
          continue;
        }
        if (identical(_budgetSignal, signal)) _budgetSignal = null;
        budgetPolls++;
        if (budgetPolls == 1) {
          // Reading the characteristic would return its stored value, not a
          // fresh credit, and could overrun the firmware's 1024-byte buffer.
          LogService.log('[BLE] TX held: waiting for overflow credit');
        }
        if (budgetPolls >= _stallPollLimit && isActive) {
          onTransportFault(
            FlipperTransportError(
              'No flow-control credit for '
              '${_stallPoll.inSeconds * _stallPollLimit}s with TX pending',
            ),
          );
          break;
        }
        continue;
      }
      budgetPolls = 0;

      await _drainBudgetCycle();
    }
    _senderRunning = false;
  }

  // Sends queued frames within one credit cycle; never sends a single byte
  // beyond the credit the firmware granted.
  Future<void> _drainBudgetCycle() async {
    var cycleRemaining = _budget;
    final cycleGen = _budgetGen;
    _budget = 0;

    while (isActive && cycleRemaining > 0) {
      if (_txQueue.isEmpty) {
        final signal = _txDataSignal = Completer<void>();
        final arrived = await _awaitSignal(
          signal,
          const Duration(milliseconds: 100),
        );
        if (!arrived || _txQueue.isEmpty) break;
      }

      final pending = _txQueue.first;
      final sendLength = pending.remainingLength < cycleRemaining
          ? pending.remainingLength
          : cycleRemaining;
      final sendEnd = pending.offset + sendLength;
      try {
        await _sendMessage(
          Uint8List.sublistView(pending.bytes, pending.offset, sendEnd),
        );
      } catch (e) {
        if (isActive) {
          onTransportFault(FlipperTransportError('BLE write failed: $e'));
        }
        return;
      }

      pending.offset = sendEnd;
      cycleRemaining -= sendLength;
      if (pending.offset == pending.bytes.length) {
        _txQueue.removeAt(0);
        pending.complete();
      }
      // A fresh credit notification is authoritative: it already accounts for
      // everything sent so far, so the old cycle's remainder must be dropped.
      if (_budgetGen != cycleGen) return;
    }

    // The firmware re-grants only after the whole credit is consumed; keep the
    // unused remainder for later frames.
    if (cycleRemaining > 0 && _budgetGen == cycleGen) {
      _budget = cycleRemaining;
    }
  }

  Future<void> _sendMessage(Uint8List data) async {
    var offset = 0;
    while (offset < data.length) {
      if (!isActive) {
        throw StateError('BLE transport closed');
      }
      final chunkEnd = (offset + _bleMtuSize).clamp(0, data.length);
      try {
        await _ops.write(
          _device.device.deviceId,
          _txSvcId,
          _txCharId,
          Uint8List.sublistView(data, offset, chunkEnd),
          withoutResponse: !_txWithResponse,
        );
      } on TimeoutException {
        // The platform callback can be lost after an acknowledged ATT write.
        // Retrying is unsafe: the peripheral may already have consumed the
        // bytes. Continue once; overflow control and the RPC ACK verify the
        // stream without duplicating this chunk or dropping the BLE link.
        if (!_txWithResponse) rethrow;
        LogService.log(
          '[BLE] write callback timed out; continuing without retry',
        );
      }
      offset = chunkEnd;
    }
  }

  // True if the signal fired within [timeout]; a timeout is a result, not an
  // exception.
  Future<bool> _awaitSignal(Completer<void> signal, Duration timeout) {
    final result = Completer<bool>();
    final timer = Timer(timeout, () {
      if (!result.isCompleted) result.complete(false);
    });
    signal.future.whenComplete(() {
      timer.cancel();
      if (!result.isCompleted) result.complete(true);
    });
    return result.future;
  }

  void _fireSignal(Completer<void>? signal) {
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _releaseSenderSignals() {
    final signals = [_budgetSignal, _txDataSignal, _rpcActiveSignal];
    _budgetSignal = null;
    _txDataSignal = null;
    _rpcActiveSignal = null;
    for (final signal in signals) {
      _fireSignal(signal);
    }
  }

  void _failAllPending(Object error) {
    final pendings = List<_BlePendingSend>.from(_txQueue);
    _txQueue.clear();
    for (final p in pendings) {
      p.fail(error);
    }
  }

  @override
  void onFaultExtra(Object error) {
    _releaseSenderSignals();
    _failAllPending(error);
    _markBleDisconnected();
    _clearBleCallbacks();
  }

  @override
  Future<void> nudgeCli() async {
    throw FlipperUnsupportedModeError(
      'CLI mode is not available over BLE connections',
    );
  }

  @override
  Future<void> doClose() async {
    _releaseSenderSignals();
    _failAllPending(StateError('BLE transport closed'));
    if (!identical(_connectionOwner, this)) {
      LogService.log(
        '[BLE] stale transport closed without platform disconnect '
        '(newer transport owns ${_device.device.deviceId})',
      );
      _markBleDisconnected();
      _clearBleCallbacks();
      return;
    }
    if (_link == _BleLinkState.disconnected) {
      if (_platformConnectionEstablished) {
        // Configured but never opened: the platform link exists and must be
        // released.
        try {
          await _ops.disconnect(_device.device.deviceId);
        } catch (e) {
          LogService.log('[BLE] disconnect failed: $e');
        }
        _markBleDisconnected();
        _clearBleCallbacks();
        return;
      }
      _connectionOwner = null;
      _clearBleCallbacks();
      return;
    }
    _link = _BleLinkState.disconnecting;
    final disconnectSignal = _disconnectSignal = Completer<void>();
    final state = await _ops.getConnectionState(_device.device.deviceId);
    if (state == _BleConnState.disconnected) {
      _markBleDisconnected();
      _clearBleCallbacks();
      return;
    }
    try {
      await _ops.disconnect(_device.device.deviceId);
    } catch (e) {
      LogService.log('[BLE] disconnect failed: $e');
      _markBleDisconnected();
      _clearBleCallbacks();
      return;
    }
    final confirmed = await _awaitSignal(
      disconnectSignal,
      const Duration(seconds: 5),
    );
    LogService.log(
      confirmed
          ? '[BLE] disconnected'
          : '[BLE] disconnect event not confirmed within 5s',
    );
    _markBleDisconnected();
    _clearBleCallbacks();
  }

  void _markBleDisconnected() {
    _link = _BleLinkState.disconnected;
    _platformConnectionEstablished = false;
    _rpcSessionActive = false;
    if (identical(_connectionOwner, this)) {
      _connectionOwner = null;
    }
    final signal = _disconnectSignal;
    _disconnectSignal = null;
    _fireSignal(signal);
  }

  void _clearBleCallbacks() {
    if (_activeTransport == this) {
      _activeTransport = null;
      _ops.onConnectionChange = null;
      _ops.onValueChange = null;
    }
  }
}

enum _BleLinkState { connected, disconnecting, disconnected }

class _BlePendingSend {
  _BlePendingSend(this.bytes);
  final Uint8List bytes;
  final Completer<void> _completer = Completer<void>();
  int offset = 0;

  Future<void> get future => _completer.future;

  int get remainingLength => bytes.length - offset;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void fail(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
