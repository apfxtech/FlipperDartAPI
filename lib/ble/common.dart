part of '../flipper_client.dart';

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

abstract class _UniversalBleTransportBase extends _Transport {
  static const String overflowCharUuid = '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const String rpcStatusCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e64fe0000';
final BleDiscoveredDevice _device;

  late final String _txSvcId;
  late final String _txCharId;
  late final String _rxSvcId;
  late final String _rxCharId;
  late final bool _txWithResponse;
  late final bool _rxUsesIndicate;
  late int _bleChunkSize;

  String? _overflowSvcId;
  String? _overflowCharId;
  String? _rpcStatusSvcId;
  String? _rpcStatusCharId;

  final List<_BlePendingSend> _txQueue = [];
  Completer<void>? _txDataSignal;

  Uint8List? _pendingBytes;

  int _budget = 0;
  int _budgetGen = 0;
  Completer<void>? _budgetSignal;
  Completer<void>? _disconnectSignal;

  bool _senderRunning = false;
  _BleConnectionPhase _connectionPhase = _BleConnectionPhase.disconnected;

  _UniversalBleTransportBase(this._device);

  // Override in subclasses to inject a delay between connect and service discovery.
  Future<void> _postConnectDelay() async {}

  // Override to skip connect() if the peripheral is already connected (macOS).
  Future<void> _connectDevice() async {
    await uble.UniversalBle.connect(_device.device.deviceId);
  }

  // Override to subscribe to extra characteristics after open (macOS rpcStatus).
  Future<void> _openExtra() async {}

  // Override to false on platforms where writing rpcStatus tears the link (macOS).
  bool get _canWriteRpcStatus => true;

  Future<void> _configure() async {
    await _connectDevice();
    await _postConnectDelay();
    int negotiatedMtu = 23;
    try {
      negotiatedMtu = await uble.UniversalBle.requestMtu(
        _device.device.deviceId,
        517,
      );
    } catch (e) {
      LogService.log(
        '[BLE] requestMtu failed: $e (using default $negotiatedMtu)',
      );
    }

    final services = await uble.UniversalBle.discoverServices(
      _device.device.deviceId,
    );
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
            txWithResponse = char.properties.contains(
              uble.CharacteristicProperty.write,
            );
          }
          if (cid == FlipperClient.bleRxUuid) {
            rxSvc = service.uuid;
            rxChar = char.uuid;
            rxUsesIndicate = char.properties.contains(
              uble.CharacteristicProperty.indicate,
            );
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
    _bleChunkSize = (negotiatedMtu - 3).clamp(20, 512);
    _overflowSvcId = overflowSvc;
    _overflowCharId = overflowChar;
    _rpcStatusSvcId = rpcStatusSvc;
    _rpcStatusCharId = rpcStatusChar;
    LogService.log(
      '[BLE] mtu=$negotiatedMtu chunk=$_bleChunkSize '
      'txWithResponse=$_txWithResponse overflowControl=true rpcStatus=true',
    );
  }

  @override
  bool get supportsCli => false;

  @override
  FlipperMode get initialMode => FlipperMode.rpc;

  @override
  Future<void> open() async {
    uble.UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (deviceId != _device.device.deviceId) return;
      if (!isConnected) {
        final wasDisconnecting =
            _connectionPhase == _BleConnectionPhase.disconnecting;
        _markBleDisconnected();
        if (!wasDisconnecting) {
          onTransportFault(StateError('BLE disconnected'));
        }
      }
    };

    uble.UniversalBle.onValueChange = (deviceId, charId, value, mtu) {
      _onValueChange(deviceId, charId, value, mtu);
    };

    _connectionPhase = _BleConnectionPhase.connected;

    if (_rxUsesIndicate) {
      await uble.UniversalBle.subscribeIndications(
        _device.device.deviceId,
        _rxSvcId,
        _rxCharId,
      );
    } else {
      await uble.UniversalBle.subscribeNotifications(
        _device.device.deviceId,
        _rxSvcId,
        _rxCharId,
      );
    }

    await uble.UniversalBle.subscribeNotifications(
      _device.device.deviceId,
      _overflowSvcId!,
      _overflowCharId!,
    );
    final initial = await uble.UniversalBle.read(
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
    if (lower == _rxCharId.toLowerCase()) {
      addBytes(value);
      return;
    }
    if (lower == _overflowCharId!.toLowerCase()) {
      _applyOverflowValue(value);
    }
  }

  void _applyOverflowValue(List<int> value) {
    final bytes = Uint8List.fromList(value);
    final view = ByteData.view(bytes.buffer);
    int remaining;
    if (bytes.length >= 4) {
      remaining = view.getUint32(0, Endian.big);
    } else if (bytes.length >= 2) {
      // Older Flipper firmware sends 2-byte uint16_t overflow counter.
      remaining = view.getUint16(0, Endian.big);
    } else {
      return;
    }
    _budget = remaining;
    _budgetGen += 1;
    LogService.log('[BLE] overflow remaining=$remaining (gen $_budgetGen)');
    final signal = _budgetSignal;
    _budgetSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    if (_closed) throw StateError('BLE transport closed');
    if (bytes.isEmpty) return;

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
        if (_budget <= 0) {
          await _waitForBudget();
          continue;
        }
        final gen = _budgetGen;
        await _sendCommandsWhileBufferNotEnd(_budget, gen);
      }
    } catch (e, st) {
      LogService.log('[BLE] sender error: $e\n$st');
      _failAllPending(e);
    } finally {
      _senderRunning = false;
    }
  }

  Future<void> _sendCommandsWhileBufferNotEnd(
    int initialBudget,
    int gen,
  ) async {
    var remaining = initialBudget;

    while (remaining > 0 && !_closed && _budgetGen == gen) {
      final pending = _takePendingBytes(remaining);
      remaining -= pending.length;

      if (remaining == 0) {
        await _bleWrite(pending);
        _budget -= pending.length;
        return;
      }

      final batch = await _readPendingCommands(
        remaining,
        waitInfinite: pending.isEmpty,
        gen: gen,
      );
      if (batch == null) {
        if (pending.isNotEmpty) {
          await _bleWrite(pending);
          _budget -= pending.length;
        }
        return;
      }

      assert(remaining >= batch.bytes.length);
      remaining -= batch.bytes.length;

      final combined = pending.isEmpty
          ? batch.bytes
          : (Uint8List(pending.length + batch.bytes.length)
              ..setRange(0, pending.length, pending)
              ..setRange(
                pending.length,
                pending.length + batch.bytes.length,
                batch.bytes,
              ));

      try {
        await _bleWrite(combined);
        _budget -= combined.length;
      } catch (e) {
        for (final entry in batch.entries) {
          if (!entry.completer.isCompleted) entry.completer.completeError(e);
        }
        rethrow;
      }
      for (final entry in batch.entries) {
        if (!entry.completer.isCompleted) entry.completer.complete();
      }
    }
  }

  Uint8List _takePendingBytes(int maxLen) {
    final pending = _pendingBytes;
    if (pending == null) return Uint8List(0);
    if (pending.length <= maxLen) {
      _pendingBytes = null;
      return pending;
    }
    final take = pending.sublist(0, maxLen);
    _pendingBytes = pending.sublist(maxLen);
    return take;
  }

  Future<_BleBatch?> _readPendingCommands(
    int maxBytes, {
    required bool waitInfinite,
    required int gen,
  }) async {
    final out = BytesBuilder(copy: false);
    final entries = <_BlePendingSend>[];
    var remaining = maxBytes;
    var firstRead = true;

    while (remaining > 0 && !_closed && _budgetGen == gen) {
      _BlePendingSend entry;
      if (_txQueue.isNotEmpty) {
        entry = _txQueue.first;
      } else if (firstRead && waitInfinite) {
        await _waitForData();
        if (_closed || _budgetGen != gen || _txQueue.isEmpty) break;
        entry = _txQueue.first;
      } else {
        // BLE RPC is sequential (send → wait for response → next send).
        // Waiting here for more commands to batch only adds latency with no benefit.
        break;
      }
      firstRead = false;

      final entryBytes = entry.bytes;
      if (remaining >= entryBytes.length) {
        out.add(entryBytes);
        remaining -= entryBytes.length;
        _txQueue.removeAt(0);
        entries.add(entry);
      } else {
        out.add(entryBytes.sublist(0, remaining));
        _pendingBytes = entryBytes.sublist(remaining);
        _txQueue.removeAt(0);
        entries.add(entry);
        remaining = 0;
      }
    }

    final result = out.takeBytes();
    if (result.isEmpty) return null;
    return _BleBatch(result, entries);
  }

  Future<void> _bleWrite(Uint8List data) async {
    var offset = 0;
    while (offset < data.length) {
      if (_closed) throw StateError('BLE transport closed');
      final end = (offset + _bleChunkSize) > data.length
          ? data.length
          : offset + _bleChunkSize;
      await uble.UniversalBle.write(
        _device.device.deviceId,
        _txSvcId,
        _txCharId,
        data.sublist(offset, end),
        withoutResponse: !_txWithResponse,
      );
      offset = end;
    }
  }

  Future<void> _waitForBudget() async {
    final completer = Completer<void>();
    _budgetSignal = completer;
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _budgetSignal = null;
      // Firmware may have missed sending a notification — re-read to unblock.
      if (!_closed && _overflowSvcId != null && _overflowCharId != null) {
        try {
          final value = await uble.UniversalBle.read(
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
      _clearBleCallbacks();
      return;
    }
    final state = await _readConnectionState();
    if (state == uble.BleConnectionState.disconnected) {
      _markBleDisconnected();
      _clearBleCallbacks();
      return;
    }
    _connectionPhase = _BleConnectionPhase.disconnecting;
    _disconnectSignal = Completer<void>();
    try {
      await uble.UniversalBle.disconnect(_device.device.deviceId);
      final stateAfterDisconnect = await _readConnectionState();
      if (stateAfterDisconnect == uble.BleConnectionState.disconnected) {
        _markBleDisconnected();
      }
      await _disconnectSignal!.future;
    } catch (e) {
      LogService.log('[BLE] disconnect failed: $e');
    } finally {
      _markBleDisconnected();
      _clearBleCallbacks();
    }
  }

  @override
  Future<void> restartRpc() async {
    final serviceId = _rpcStatusSvcId;
    final charId = _rpcStatusCharId;
    if (serviceId == null || charId == null || _closed) return;
    if (!_canWriteRpcStatus) return;

    await uble.UniversalBle.write(
      _device.device.deviceId,
      serviceId,
      charId,
      Uint8List(1),
    );
    LogService.log('[BLE] RPC restart requested');
  }

  Future<uble.BleConnectionState?> _readConnectionState() async {
    try {
      return await uble.UniversalBle.getConnectionState(
        _device.device.deviceId,
      );
    } catch (e) {
      LogService.log('[BLE] getConnectionState failed: $e');
      return null;
    }
  }

  void _markBleDisconnected() {
    _connectionPhase = _BleConnectionPhase.disconnected;
    final signal = _disconnectSignal;
    _disconnectSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _clearBleCallbacks() {
    uble.UniversalBle.onConnectionChange = null;
    uble.UniversalBle.onValueChange = null;
  }
}

enum _BleConnectionPhase { disconnected, connected, disconnecting }

class _BlePendingSend {
  _BlePendingSend(this.bytes, this.completer);
  final Uint8List bytes;
  final Completer<void> completer;
}

class _BleBatch {
  _BleBatch(this.bytes, this.entries);
  final Uint8List bytes;
  final List<_BlePendingSend> entries;
}
