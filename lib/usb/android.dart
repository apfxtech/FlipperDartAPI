part of '../flipper_client.dart';

class _AndroidUsbPlatform implements _UsbPlatform {
  const _AndroidUsbPlatform();

  @override
  Future<List<FlipperDevice>> loadDevices() async {
    final devices = await UsbSerial.listDevices();
    return devices
        .map(
          (device) => FlipperDevice(
            id: '${device.vid}:${device.pid}',
            name: (device.productName?.isNotEmpty == true)
                ? device.productName!
                : 'USB VID:0x${device.vid?.toRadixString(16) ?? '?'} PID:0x${device.pid?.toRadixString(16) ?? '?'}',
            link: FlipperLink.usb,
            source: AndroidUsbDiscoveredDevice(device),
            vendorId: device.vid,
            productId: device.pid,
          ),
        )
        .toList(growable: false);
  }

  @override
  bool includeDevice(FlipperDevice device) {
    final source = device.source;
    if (source is! AndroidUsbDiscoveredDevice) return false;
    return includeUsbDevice(source.usbDevice);
  }

  bool includeUsbDevice(UsbDevice device) {
    const flipperVid = 0x0483;
    const flipperPid = 0x5740;
    if (device.vid == flipperVid && device.pid == flipperPid) return true;
    if (device.vid == flipperVid) return true;

    final haystack = [
      device.productName ?? '',
      device.manufacturerName ?? '',
      device.deviceName,
    ].join(' ').toLowerCase();
    return haystack.contains('flipper') ||
        haystack.contains('stm32') ||
        haystack.contains('stmicroelectronics') ||
        haystack.contains('virtual com') ||
        haystack.contains('usbmodem') ||
        haystack.contains('usbserial') ||
        haystack.contains('flip_');
  }

  @override
  Future<_Transport> openTransport(UsbDiscoveredDevice device) {
    if (device is! AndroidUsbDiscoveredDevice) {
      throw UnsupportedError(
        'Android USB transport requires Android USB device',
      );
    }
    return _AndroidUsbTransport.create(device);
  }
}

class _AndroidUsbTransport extends _Transport {
  final UsbPort _port;
  StreamSubscription<Uint8List>? _inputSub;

  _AndroidUsbTransport._(this._port);

  static Future<_AndroidUsbTransport> create(
    AndroidUsbDiscoveredDevice device,
  ) async {
    final port = await device.usbDevice.create();
    if (port == null) {
      throw StateError('USB permission denied or port unavailable');
    }
    final opened = await port.open();
    if (!opened) {
      throw StateError('Failed to open USB port');
    }
    await port.setPortParameters(
      230400,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    return _AndroidUsbTransport._(port);
  }

  @override
  bool get supportsCli => true;

  @override
  FlipperMode get initialMode => FlipperMode.cli;

  @override
  int get storageChunkSize => 1024;

  @override
  Future<void> open() async {
    _inputSub = _port.inputStream?.listen(
      addBytes,
      onError: (Object error, StackTrace stackTrace) {
        LogService.log('[FlipperClient] Android USB read error: $error');
        onTransportFault(error);
      },
      onDone: () {
        onTransportFault(StateError('USB input stream closed'));
      },
    );
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    await _port.write(bytes);
  }

  @override
  Future<void> nudgeCli() async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    await _port.setDTR(false);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await _port.setDTR(true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await writeAscii('\r');
  }

  @override
  Future<void> doClose() async {
    await _inputSub?.cancel();
    _inputSub = null;
    try {
      await _port.close();
    } catch (e) {
      LogService.log('[FlipperClient] Android USB close error: $e');
    }
  }
}
