part of '../flipper_client.dart';

// ── BLE service / characteristic model ──────────────────────────────────────

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

// ── BLE operations adapter ───────────────────────────────────────────────────

abstract class _BleOps {
  // Connection / disconnection change callback (set by transport, cleared on close)
  set onConnectionChange(
    void Function(String deviceId, bool isConnected, String? error)? cb,
  );

  // Characteristic value change callback
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

// ── universal_ble adapter (all platforms except macOS) ──────────────────────

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
  }) => uble.UniversalBle.write(
    deviceId,
    svcId,
    charId,
    data,
    withoutResponse: withoutResponse,
  );

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

// ── _BlePlatform interface ───────────────────────────────────────────────────

abstract class _BlePlatform {
  Future<void> requestPermissions();

  // Already-bonded / system-known devices. This is an instant lookup, not a
  // scan, so it is queried once at the start of every scan to surface devices
  // that are connected but not currently advertising.
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

  // Unified, platform-independent Flipper identification. A device is a Flipper
  // if it advertises the Flipper GATT service, carries the Flipper MAC OUI, or
  // its advertised name contains "flipper" / "flip_".
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

// ── Base BLE transport ───────────────────────────────────────────────────────
//
// Firmware contract (targets/f7/ble_glue/services/serial_service.c +
// applications/services/bt/bt_service/bt.c):
//
//  * Flow control: the firmware grants a credit of RPC_BUFFER_SIZE (1024)
//    bytes. It counts every byte written to the RX characteristic against
//    that credit and sends a flow-control notification — always carrying the
//    full buffer size — only after the credit hit zero AND its RPC thread
//    drained the buffer. Exceeding the credit risks dropped bytes (the GAP
//    thread feeds RPC with a 1 s timeout), which desynchronizes the protobuf
//    varint framing; the firmware then answers ERROR_DECODE and restarts its
//    whole BLE stack — an "unexpected" link drop on the client side.
//
//  * Session readiness: the rpcStatus characteristic is 1 only while the
//    firmware's RPC session is open. The session opens on the GAP "connected"
//    event (after pairing), which can be LATER than our GATT subscriptions:
//    anything written before that is silently discarded by the firmware
//    (serial-service callback is still NULL), desynchronizing framing the
//    same way. TX therefore waits for rpcStatus to become active, and a
//    mid-session transition to 0 means the firmware closed the session.
//
//  * Writing 0 to rpcStatus asks the firmware to restart its BLE stack
//    (deliberate link drop) — never do that as an "error recovery".
abstract class _UniversalBleTransportBase extends _Transport {
  static const String overflowCharUuid = '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const String rpcStatusCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e64fe0000';
  static const int _bleChunkSize = 512;
  static const int _minBleMtuSize = 20;
  // Flipper supports ATT_MTU=414, leaving 411 bytes for a Write Command.
  static const int _maxBleMtuSize = 411;
  // CoreBluetooth (and most backends) never time a connect attempt out on
  // their own — a wedged peripheral leaves the future pending forever and the
  // UI silent. Encryption of a bonded link happens inside this step too, so
  // the budget covers a slow re-encryption but not an eternal hang.
  static const Duration _connectTimeout = Duration(seconds: 20);

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

  // Flow-control credit: bytes we may still send before the next firmware
  // notification. _budgetGen lets a send cycle detect that a fresh
  // (authoritative) credit arrived while a write was in flight.
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

  static _UniversalBleTransportBase? _activeTransport;

  _UniversalBleTransportBase(this._device, this._ops);

  // Override to subscribe to extra characteristics / settle delays after the
  // base subscriptions are in place (e.g. macOS connection-parameter settle).
  Future<void> _openExtra() async {}

  Future<void> _configure() async {
    final deviceId = _device.device.deviceId;
    var connectTimedOut = false;
    await _ops.connect(deviceId).timeout(
      _connectTimeout,
      onTimeout: () {
        connectTimedOut = true;
      },
    );
    if (connectTimedOut) {
      // Cancel the still-pending platform connect attempt so the next try
      // starts clean instead of stacking on a wedged one.
      unawaited(
        _ops.disconnect(deviceId).catchError((Object e) {
          LogService.log('[BLE] connect-timeout cancel failed: $e');
        }),
      );
      throw FlipperTransportError(
        'BLE connect timeout after ${_connectTimeout.inSeconds}s '
        '(device unreachable, or its bond/encryption is stalled — '
        'try forgetting the pairing on both sides)',
      );
    }
    int negotiatedMtu = 23;
    try {
      negotiatedMtu = await _ops.requestMtu(_device.device.deviceId, 517);
    } catch (e) {
      LogService.log(
        '[BLE] requestMtu failed: $e (using default $negotiatedMtu)',
      );
    }

    final services = await _ops.discoverServices(_device.device.deviceId);
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
          txWithResponse = !char.canWriteNoRsp;
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
      '[BLE] negotiatedMtu=$negotiatedMtu chunk=$_bleChunkSize '
      'mtu=$_bleMtuSize '
      'txWithResponse=$_txWithResponse overflowControl=true rpcStatus=true',
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
      LogService.log(
        '[BLE] rpcStatus subscribed, sessionActive=$_rpcSessionActive',
      );
    } catch (e) {
      // Without rpcStatus we cannot observe session readiness; fall back to
      // ungated TX (pre-existing behavior) instead of blocking forever.
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
        'link=${_link.name} budget=$_budget txQueue=${_txQueue.length} '
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
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    int remaining;
    if (bytes.length >= 4) {
      remaining = view.getUint32(0, Endian.big);
    } else if (bytes.length >= 2) {
      remaining = view.getUint16(0, Endian.big);
    } else {
      LogService.log('[BLE] overflow: payload too short hex=[$hex]');
      return;
    }
    _budget = remaining;
    _budgetGen += 1;
    LogService.log(
      '[BLE] overflow remaining=$remaining hex=[$hex] (gen $_budgetGen)',
    );
    _fireSignal(_budgetSignal);
    _budgetSignal = null;
  }

  void _applyRpcStatusValue(List<int> value) {
    final active = value.any((b) => b != 0);
    if (active == _rpcSessionActive) return;
    _rpcSessionActive = active;
    LogService.log(
      '[BLE] rpcStatus -> ${active ? 'active' : 'inactive'} (link=${_link.name})',
    );
    if (active) {
      _fireSignal(_rpcActiveSignal);
      _rpcActiveSignal = null;
      return;
    }
    if (!isActive || _link != _BleLinkState.connected) return;
    // The firmware deactivated the RPC session mid-connection. It does this
    // right before tearing the link down (e.g. after a protobuf decode error),
    // so report the real cause now instead of a generic timeout later.
    onTransportFault(
      FlipperTransportError('Flipper closed the RPC session (rpcStatus=0)'),
    );
  }

  // ── TX path ────────────────────────────────────────────────────────────────

  @override
  Future<void> rawWrite(Uint8List bytes) {
    if (!isActive) {
      return Future.error(StateError('BLE transport closed'));
    }
    if (bytes.isEmpty) return Future.value();

    // The returned future resolves at different points per write mode:
    //   WWNR — when the sender *picks up* the frame (rendezvous, like
    //           writeSync + onSendCallback in flipper-android); the BLE write
    //           continues in the background and the overflow credit is the
    //           real backpressure. Queue depth stays ≤1 frame.
    //   WR   — after the peer ACKed the frame's last chunk.
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
    while (isActive) {
      if (_txQueue.isEmpty) {
        final signal = _txDataSignal = Completer<void>();
        await signal.future;
        continue;
      }
      if (_rpcStatusAvailable && !_rpcSessionActive) {
        // Bytes written before the firmware opens its RPC session are silently
        // dropped on the device and desynchronize the protobuf framing — hold
        // TX until the session reports active.
        final signal = _rpcActiveSignal = Completer<void>();
        final became = await _awaitSignal(signal, const Duration(seconds: 5));
        if (!became && isActive) {
          LogService.log('[BLE] TX held: firmware RPC session not active yet');
        }
        continue;
      }
      await _sendBudgetCycle();
    }
    _senderRunning = false;
  }

  /// Sends queued frames within one flow-control credit cycle. Never sends a
  /// single byte beyond the credit the firmware granted.
  Future<void> _sendBudgetCycle() async {
    if (_budget <= 0) {
      final signal = _budgetSignal = Completer<void>();
      final granted = await _awaitSignal(signal, const Duration(seconds: 5));
      if (!granted) {
        if (identical(_budgetSignal, signal)) _budgetSignal = null;
        // A characteristic read would return the stored value, not a fresh
        // firmware credit; reusing it can overrun the 1024-byte RPC buffer.
        if (isActive) {
          LogService.log('[BLE] waiting for fresh overflow notification');
        }
      }
      return;
    }

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
      if (!_txWithResponse) {
        // Pickup rendezvous: let the producer build the next frame while this
        // one is being radioed out.
        pending.complete();
      }
      final sendLength = [
        pending.remainingLength,
        cycleRemaining,
        _bleMtuSize,
      ].reduce((a, b) => a < b ? a : b);
      final sendEnd = pending.offset + sendLength;

      Object? writeError;
      try {
        await _sendMessage(
          Uint8List.sublistView(pending.bytes, pending.offset, sendEnd),
        );
      } catch (e) {
        writeError = e;
      }
      if (writeError != null) {
        if (isActive) {
          onTransportFault(FlipperTransportError('BLE write failed: $writeError'));
        }
        return;
      }

      pending.offset = sendEnd;
      cycleRemaining -= sendLength;
      if (pending.offset == pending.bytes.length) {
        _txQueue.removeAt(0);
        // WR mode resolves after the peer ACKed the last chunk (no-op for
        // WWNR, whose completer fired at pickup).
        pending.complete();
      }
      if (_budgetGen != cycleGen) {
        // A fresh credit notification arrived while writing; it is
        // authoritative and already accounts for everything sent so far.
        return;
      }
    }

    // Keep unused capacity for later frames (the firmware only re-grants
    // after the whole credit is consumed). A newer notification must not be
    // overwritten.
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
      await _ops.write(
        _device.device.deviceId,
        _txSvcId,
        _txCharId,
        Uint8List.sublistView(data, offset, chunkEnd),
        withoutResponse: !_txWithResponse,
      );
      offset = chunkEnd;
    }
  }

  /// Waits for [signal] to fire, up to [timeout]. Returns whether it fired —
  /// a timeout is a result, not an exception.
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

  // ── Shutdown ───────────────────────────────────────────────────────────────

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
    if (_link == _BleLinkState.disconnected) {
      LogService.log('[BLE] already disconnected before close');
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
    LogService.log('[BLE] close requested; disconnecting device');
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
    if (!confirmed) {
      LogService.log('[BLE] disconnect event timeout after close request');
    }
    _markBleDisconnected();
    _clearBleCallbacks();
  }

  void _markBleDisconnected() {
    _link = _BleLinkState.disconnected;
    _rpcSessionActive = false;
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
