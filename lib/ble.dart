part of 'flipper_client.dart';

class _BleTransport extends _Transport {
  static const String overflowCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const Duration _serialSendWaitTimeout = Duration(milliseconds: 100);

  final BleDiscoveredDevice _device;

  late final String _txSvcId;
  late final String _txCharId;
  late final String _rxSvcId;
  late final String _rxCharId;
  late final bool _txWithResponse;
  late final bool _rxUsesIndicate;
  late final int _bleChunkSize;

  String? _overflowSvcId;
  String? _overflowCharId;
  bool _hasOverflowControl = false;

  final List<_BlePendingSend> _txQueue = [];
  Completer<void>? _txDataSignal;

  Uint8List? _pendingBytes;

  int _budget = 0;
  int _budgetGen = 0;
  Completer<void>? _budgetSignal;

  bool _senderRunning = false;

  _BleTransport._(this._device);

  static Future<_BleTransport> create(BleDiscoveredDevice device) async {
    final transport = _BleTransport._(device);
    await transport._configure();
    return transport;
  }

  Future<void> _configure() async {
    await uble.UniversalBle.connect(_device.device.deviceId);
    int negotiatedMtu = 23;
    try {
      negotiatedMtu =
          await uble.UniversalBle.requestMtu(_device.device.deviceId, 517);
    } catch (e) {
      LogService.log(
          '[BLE] requestMtu failed: $e (using default $negotiatedMtu)');
    }

    final services =
        await uble.UniversalBle.discoverServices(_device.device.deviceId);
    String? txSvc;
    String? txChar;
    String? rxSvc;
    String? rxChar;
    String? overflowSvc;
    String? overflowChar;
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
            txWithResponse =
                char.properties.contains(uble.CharacteristicProperty.write);
          }
          if (cid == FlipperClient.bleRxUuid) {
            rxSvc = service.uuid;
            rxChar = char.uuid;
            rxUsesIndicate =
                char.properties.contains(uble.CharacteristicProperty.indicate);
          }
          if (cid == overflowCharUuid) {
            overflowSvc = service.uuid;
            overflowChar = char.uuid;
          }
        }
      }
    }

    if (txSvc == null || txChar == null || rxSvc == null || rxChar == null) {
      for (final service in services) {
        for (final char in service.characteristics) {
          if (txSvc == null &&
              (char.properties.contains(uble.CharacteristicProperty.write) ||
                  char.properties.contains(
                    uble.CharacteristicProperty.writeWithoutResponse,
                  ))) {
            txSvc = service.uuid;
            txChar = char.uuid;
            txWithResponse =
                char.properties.contains(uble.CharacteristicProperty.write);
          }
          if (rxSvc == null &&
              char.properties.contains(uble.CharacteristicProperty.indicate)) {
            rxSvc = service.uuid;
            rxChar = char.uuid;
            rxUsesIndicate = true;
          } else if (rxSvc == null &&
              char.properties.contains(uble.CharacteristicProperty.notify)) {
            rxSvc = service.uuid;
            rxChar = char.uuid;
            rxUsesIndicate = false;
          }
        }
      }
    }

    if (txSvc == null || txChar == null || rxSvc == null || rxChar == null) {
      throw StateError('No suitable BLE characteristics');
    }

    _txSvcId = txSvc;
    _txCharId = txChar;
    _rxSvcId = rxSvc;
    _rxCharId = rxChar;
    _txWithResponse = txWithResponse;
    _rxUsesIndicate = rxUsesIndicate;
    _bleChunkSize = (negotiatedMtu - 3).clamp(20, 512);
    _overflowSvcId = overflowSvc;
    _overflowCharId = overflowChar;
    _hasOverflowControl = overflowSvc != null && overflowChar != null;
    LogService.log(
      '[BLE] mtu=$negotiatedMtu chunk=$_bleChunkSize '
      'txWithResponse=$_txWithResponse overflowControl=$_hasOverflowControl',
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
        onTransportFault(StateError('BLE disconnected'));
      }
    };

    uble.UniversalBle.onValueChange = (deviceId, charId, value, mtu) {
      _onValueChange(deviceId, charId, value, mtu);
    };

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

    if (_hasOverflowControl) {
      try {
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
      } catch (e) {
        LogService.log('[BLE] overflow init failed: $e, disabling throttler');
        _hasOverflowControl = false;
      }
    }

    if (_hasOverflowControl) {
      _startSender();
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
    if (lower == _rxCharId.toLowerCase()) {
      addBytes(value);
      return;
    }
    if (_hasOverflowControl &&
        _overflowCharId != null &&
        lower == _overflowCharId!.toLowerCase()) {
      _applyOverflowValue(value);
    }
  }

  void _applyOverflowValue(List<int> value) {
    if (value.length < 4) return;
    final view = ByteData.view(Uint8List.fromList(value).buffer);
    final remaining = view.getInt32(0, Endian.big);
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

    if (!_hasOverflowControl) {
      await _writeRawDirect(bytes);
      return;
    }

    final completer = Completer<void>();
    _txQueue.add(_BlePendingSend(bytes, completer));
    final sig = _txDataSignal;
    _txDataSignal = null;
    if (sig != null && !sig.isCompleted) sig.complete();
    _startSender();
    await completer.future;
  }

  Future<void> _writeRawDirect(Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_closed) throw StateError('BLE transport closed');
      final end = (offset + _bleChunkSize) > bytes.length
          ? bytes.length
          : offset + _bleChunkSize;
      await uble.UniversalBle.write(
        _device.device.deviceId,
        _txSvcId,
        _txCharId,
        bytes.sublist(offset, end),
        withoutResponse: !_txWithResponse,
      );
      offset = end;
    }
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

  Future<void> _sendCommandsWhileBufferNotEnd(int initialBudget, int gen) async {
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
            ..setRange(pending.length, pending.length + batch.bytes.length,
                batch.bytes));

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
        final got = await _waitForDataWithTimeout(_serialSendWaitTimeout);
        if (!got || _closed || _budgetGen != gen || _txQueue.isEmpty) break;
        entry = _txQueue.first;
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
    await completer.future;
  }

  Future<void> _waitForData() async {
    final completer = Completer<void>();
    _txDataSignal = completer;
    await completer.future;
  }

  Future<bool> _waitForDataWithTimeout(Duration timeout) async {
    if (_txQueue.isNotEmpty) return true;
    final completer = Completer<void>();
    _txDataSignal = completer;
    try {
      await completer.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
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
    uble.UniversalBle.onConnectionChange = null;
    uble.UniversalBle.onValueChange = null;
    try {
      await uble.UniversalBle.disconnect(_device.device.deviceId);
    } catch (_) {}
  }
}

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

extension FlipperBleApi on FlipperClient {
  Stream<FlipperDevice> get bleDevicesStream => devicesStream.asyncExpand(
        (devices) => Stream.fromIterable(
          devices.where((device) => device.isBle),
        ),
      );
}
