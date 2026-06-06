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

  Iterable<uble.ScanFilter?> get scanFilters;

  Future<List<BleDiscoveredDevice>> loadKnownDevices();

  bool includeDevice(BleDiscoveredDevice device);

  Future<List<BleDiscoveredDevice>> resolveScanResults(
    Iterable<BleDiscoveredDevice> devices,
  );

  Future<_Transport> openTransport(BleDiscoveredDevice device);
}

abstract class _UniversalBlePlatformBase implements _BlePlatform {
  const _UniversalBlePlatformBase();

  @override
  Iterable<uble.ScanFilter?> get scanFilters => const [null];

  @override
  Future<List<BleDiscoveredDevice>> loadKnownDevices() async {
    return const <BleDiscoveredDevice>[];
  }

  @override
  Future<List<BleDiscoveredDevice>> resolveScanResults(
    Iterable<BleDiscoveredDevice> devices,
  ) async {
    return const <BleDiscoveredDevice>[];
  }
}

// ── Base BLE transport ───────────────────────────────────────────────────────

abstract class _UniversalBleTransportBase extends _Transport {
  static const String overflowCharUuid = '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const String rpcStatusCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e64fe0000';
  static const int _bleChunkSize = 512;
  static const int _minBleMtuSize = 20;
  static const int _maxBleMtuSize = 160;

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

  final List<_BlePendingSend> _txQueue = [];
  Completer<void>? _txDataSignal;

  int _budget = 0;
  int _budgetGen = 0;
  Completer<void>? _budgetSignal;
  Completer<void>? _disconnectSignal;

  bool _senderRunning = false;
  _BleConnectionPhase _connectionPhase = _BleConnectionPhase.disconnected;

  static _UniversalBleTransportBase? _activeTransport;

  _UniversalBleTransportBase(this._device, this._ops);

  // Override to inject a delay between connect and service discovery.
  Future<void> _postConnectDelay() async {}

  // Override to skip connect() if the peripheral is already connected.
  Future<void> _connectDevice() async {
    await _ops.connect(_device.device.deviceId);
  }

  // Override to subscribe to extra characteristics after open (e.g. macOS rpcStatus).
  Future<void> _openExtra() async {}

  // Override to false on platforms where writing rpcStatus tears the link (macOS).
  bool get _canWriteRpcStatus => true;

  bool _txUsesWriteWithResponse(_BleChar char) => !char.canWriteNoRsp;

  Future<void> _configure() async {
    await _connectDevice();
    await _postConnectDelay();
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
      for (final char in service.characteristics) {
        final cid = char.uuid.toLowerCase();
        if (sid == FlipperClient.bleServiceUuid) {
          if (cid == FlipperClient.bleTxUuid) {
            txSvc = service.uuid;
            txChar = char.uuid;
            txWithResponse = _txUsesWriteWithResponse(char);
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
    }

    final missing = <String>[
      if (txSvc == null || txChar == null) 'tx($FlipperClient.bleTxUuid)',
      if (rxSvc == null || rxChar == null) 'rx($FlipperClient.bleRxUuid)',
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
    _ops.onConnectionChange = (deviceId, isConnected, error) {
      if (deviceId != _device.device.deviceId) return;
      if (!isConnected) {
        final wasDisconnecting =
            _connectionPhase == _BleConnectionPhase.disconnecting;
        final platformError = error?.trim();
        final reason = platformError == null || platformError.isEmpty
            ? 'backend connectionChange disconnected without platform reason '
                  '(likely supervision timeout / peer reset / out of range)'
            : 'backend connectionChange disconnected: $platformError';
        LogService.log(
          '[BLE] onConnectionChange isConnected=false '
          'phase=$_connectionPhase budget=$_budget txQueue=${_txQueue.length} '
          'platformError=${platformError ?? '<null>'}',
        );
        _markBleDisconnected(reason);
        if (!wasDisconnecting) {
          onTransportFault(FlipperTransportError('BLE $reason'));
        }
      }
    };

    _ops.onValueChange = (deviceId, charId, value, mtu) {
      _onValueChange(deviceId, charId, value, mtu);
    };

    _connectionPhase = _BleConnectionPhase.connected;

    if (_rxUsesIndicate) {
      await _ops.subscribeIndications(
        _device.device.deviceId,
        _rxSvcId,
        _rxCharId,
      );
    } else {
      await _ops.subscribeNotifications(
        _device.device.deviceId,
        _rxSvcId,
        _rxCharId,
      );
    }

    await _ops.subscribeNotifications(
      _device.device.deviceId,
      _overflowSvcId!,
      _overflowCharId!,
    );
    final initial = await _ops.read(
      _device.device.deviceId,
      _overflowSvcId!,
      _overflowCharId!,
    );
    _applyOverflowValue(initial);
    await _openExtra();
    _startSender();
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
    final signal = _budgetSignal;
    _budgetSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    if (_closed) throw StateError('BLE transport closed');
    if (bytes.isEmpty) return;

    // Both WWNR and WR block on a completer, but they fire at different points:
    //   WWNR — fires when sender *picks up* the frame (RENDEZVOUS, like writeSync +
    //           onSendCallback in flipper-android). BLE write runs async in background.
    //           Queue depth stays ≤1 frame; overflow budget is the backpressure.
    //   WR   — fires after the BLE write is ACK'd by the peer.
    final completer = Completer<void>();
    _txQueue.add(_BlePendingSend(bytes, completer));
    final sig = _txDataSignal;
    _txDataSignal = null;
    if (sig != null && !sig.isCompleted) sig.complete();
    _startSender();
    await completer.future;
  }

  void _startSender() {
    if (_senderRunning) return;
    _senderRunning = true;
    unawaited(_runSender());
  }

  Future<void> _runSender() async {
    try {
      while (!_closed) {
        if (_txQueue.isEmpty) {
          await _waitForData();
          continue;
        }

        if (_txWithResponse) {
          // WR: completer fires AFTER BLE ACK (peer confirmed receipt).
          final pending = _txQueue.removeAt(0);
          try {
            await _sendMessage(pending.bytes);
            if (!pending.completer.isCompleted) pending.completer.complete();
          } catch (e) {
            if (!pending.completer.isCompleted) pending.completer.completeError(e);
            if (_closed) break;
            onTransportFault(e);
            break;
          }
        } else {
          // WWNR: overflow-driven.
          // Wait for firmware buffer signal, then drain up to budget bytes.
          // Each frame's completer fires on PICKUP (before BLE write) so rawWrite
          // returns and the caller can produce the next frame. BLE write runs async.
          await _waitForOverflowBudget();
          if (_closed) break;

          var cycleRemaining = _budget;
          _budget = 0;

          while (!_closed && cycleRemaining > 0) {
            if (_txQueue.isEmpty) {
              try {
                await _waitForData().timeout(const Duration(milliseconds: 100));
              } on TimeoutException {
                break;
              }
              if (_txQueue.isEmpty) break;
            }
            final pending = _txQueue.removeAt(0);
            // Signal pickup before the BLE write so the producer (rawWrite caller)
            // can enqueue the next frame while this one is being sent to the radio.
            if (!pending.completer.isCompleted) pending.completer.complete();
            try {
              await _sendMessage(pending.bytes);
              cycleRemaining -= pending.bytes.length;
            } catch (e) {
              if (_closed) break;
              onTransportFault(e);
              return;
            }
          }
        }
      }
    } catch (e, st) {
      LogService.log('[BLE] sender error: $e\n$st');
      _failAllPending(e);
    } finally {
      _senderRunning = false;
    }
  }

  Future<void> _sendMessage(Uint8List data) async {
    var offset = 0;
    while (offset < data.length) {
      if (_closed) throw StateError('BLE transport closed');
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

  Future<void> _waitForOverflowBudget() async {
    while (!_closed && _budget <= 0) {
      final completer = Completer<void>();
      _budgetSignal = completer;
      try {
        await completer.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _budgetSignal = null;
        if (!_closed && _overflowSvcId != null && _overflowCharId != null) {
          try {
            final value = await _ops.read(
              _device.device.deviceId,
              _overflowSvcId!,
              _overflowCharId!,
            );
            _applyOverflowValue(value);
            LogService.log('[BLE] overflow re-read after budget timeout');
          } catch (e) {
            LogService.log('[BLE] overflow re-read failed: $e');
          }
        }
      }
    }
  }

  Future<void> _waitForData() async {
    final completer = Completer<void>();
    _txDataSignal = completer;
    await completer.future;
  }

  void _failAllPending(Object error) {
    final pendings = List<_BlePendingSend>.from(_txQueue);
    _txQueue.clear();
    for (final p in pendings) {
      if (!p.completer.isCompleted) p.completer.completeError(error);
    }
  }

  @override
  void onFaultExtra(Object error) {
    final budgetSignal = _budgetSignal;
    _budgetSignal = null;
    if (budgetSignal != null && !budgetSignal.isCompleted) {
      budgetSignal.complete();
    }
    final dataSignal = _txDataSignal;
    _txDataSignal = null;
    if (dataSignal != null && !dataSignal.isCompleted) dataSignal.complete();
    _failAllPending(error);
    _markBleDisconnected('transport fault: $error');
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
    final budgetSignal = _budgetSignal;
    _budgetSignal = null;
    if (budgetSignal != null && !budgetSignal.isCompleted) {
      budgetSignal.complete();
    }
    final dataSignal = _txDataSignal;
    _txDataSignal = null;
    if (dataSignal != null && !dataSignal.isCompleted) dataSignal.complete();
    _failAllPending(StateError('BLE transport closed'));
    if (_connectionPhase == _BleConnectionPhase.disconnected) {
      LogService.log('[BLE] already disconnected before close');
      _clearBleCallbacks();
      return;
    }
    // Arm signal and phase before any async call so a platform disconnect
    // event that fires during _readConnectionState() completes the signal
    // instead of being silently dropped.
    _connectionPhase = _BleConnectionPhase.disconnecting;
    _disconnectSignal = Completer<void>();
    final state = await _readConnectionState();
    if (state == _BleConnState.disconnected) {
      _markBleDisconnected(
        'close requested; backend state already disconnected',
      );
      _clearBleCallbacks();
      return;
    }
    LogService.log('[BLE] close requested; disconnecting device');
    try {
      await _ops.disconnect(_device.device.deviceId);
      final stateAfterDisconnect = await _readConnectionState();
      if (stateAfterDisconnect == _BleConnState.disconnected) {
        _markBleDisconnected('close requested; backend confirmed disconnected');
      }
      await _disconnectSignal!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          LogService.log('[BLE] disconnect event timeout after close request');
        },
      );
    } catch (e) {
      LogService.log('[BLE] disconnect failed: $e');
    } finally {
      _markBleDisconnected('close cleanup finished');
      _clearBleCallbacks();
    }
  }

  @override
  Future<void> restartRpc() async {
    final serviceId = _rpcStatusSvcId;
    final charId = _rpcStatusCharId;
    if (serviceId == null || charId == null || _closed) return;
    if (!_canWriteRpcStatus) return;

    await _ops.write(_device.device.deviceId, serviceId, charId, Uint8List(1));
    LogService.log('[BLE] RPC restart requested');
  }

  Future<_BleConnState?> _readConnectionState() async {
    return _ops.getConnectionState(_device.device.deviceId);
  }

  void _markBleDisconnected(String reason) {
    if (_connectionPhase != _BleConnectionPhase.disconnected) {
      LogService.log('[BLE] state -> disconnected: $reason');
    } else {
      LogService.log('[BLE] remains disconnected: $reason');
    }
    _connectionPhase = _BleConnectionPhase.disconnected;
    final signal = _disconnectSignal;
    _disconnectSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _clearBleCallbacks() {
    if (_activeTransport == this) {
      _activeTransport = null;
      _ops.onConnectionChange = null;
      _ops.onValueChange = null;
    }
  }
}

enum _BleConnectionPhase { disconnected, connected, disconnecting }

class _BlePendingSend {
  _BlePendingSend(this.bytes, this.completer);
  final Uint8List bytes;
  final Completer<void> completer;
}
