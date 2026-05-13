part of 'flipper_client.dart';

class _BleTransport extends _Transport {
  static const String overflowCharUuid =
      '19ed82ae-ed21-4c9d-4145-228e63fe0000';
  static const Duration _bufferWaitTimeout = Duration(seconds: 5);
  static const Duration _writeWithoutResponsePace = Duration(milliseconds: 4);

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
  int _remainingBuffer = 0;
  Completer<void>? _bufferSignal;

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
          await uble.UniversalBle.requestMtu(_device.device.deviceId, 512);
    } catch (_) {}

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
                char.properties.contains(uble.CharacteristicProperty.write) &&
                    !char.properties.contains(
                      uble.CharacteristicProperty.writeWithoutResponse,
                    );
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
                char.properties.contains(uble.CharacteristicProperty.write) &&
                    !char.properties.contains(
                      uble.CharacteristicProperty.writeWithoutResponse,
                    );
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
    LogService.log('[BLE] overflow remaining=$remaining');
    _remainingBuffer = remaining;
    final signal = _bufferSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_closed) {
        throw StateError('BLE transport closed');
      }

      int chunkLimit = _bleChunkSize;
      if (_hasOverflowControl) {
        while (_remainingBuffer <= 0 && !_closed) {
          await _waitForBufferUpdate();
        }
        if (_closed) {
          throw StateError('BLE transport closed');
        }
        chunkLimit = _remainingBuffer < _bleChunkSize
            ? _remainingBuffer
            : _bleChunkSize;
      }

      final end = (offset + chunkLimit) > bytes.length
          ? bytes.length
          : offset + chunkLimit;
      final chunk = bytes.sublist(offset, end);

      await uble.UniversalBle.write(
        _device.device.deviceId,
        _txSvcId,
        _txCharId,
        chunk,
        withoutResponse: !_txWithResponse,
      );

      if (_hasOverflowControl) {
        _remainingBuffer -= chunk.length;
      }
      offset = end;

      if (!_txWithResponse && !_hasOverflowControl) {
        await Future<void>.delayed(_writeWithoutResponsePace);
      }
    }
  }

  Future<void> _waitForBufferUpdate() {
    final completer = Completer<void>();
    _bufferSignal = completer;
    return completer.future.timeout(
      _bufferWaitTimeout,
      onTimeout: () {
        LogService.log('[BLE] overflow buffer wait timeout');
      },
    );
  }

  @override
  void onFaultExtra(Object error) {
    final signal = _bufferSignal;
    _bufferSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  Future<void> nudgeCli() async {
    throw FlipperUnsupportedModeError(
      'CLI mode is not available over BLE connections',
    );
  }

  @override
  Future<void> doClose() async {
    final signal = _bufferSignal;
    _bufferSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
    uble.UniversalBle.onConnectionChange = null;
    uble.UniversalBle.onValueChange = null;
    try {
      await uble.UniversalBle.disconnect(_device.device.deviceId);
    } catch (_) {}
  }
}

extension FlipperBleApi on FlipperClient {
  Stream<FlipperDevice> get bleDevicesStream => devicesStream.asyncExpand(
        (devices) => Stream.fromIterable(
          devices.where((device) => device.isBle),
        ),
      );
}
