part of '../flipper_client.dart';

class _MacosUsbPlatform extends _SerialUsbPlatformBase {
  const _MacosUsbPlatform();

  @override
  Future<List<FlipperDevice>> loadDevices() async {
    final result = <FlipperDevice>[];
    final availablePorts = _readSerialProperty(() => SerialPort.availablePorts);
    for (final portName in availablePorts ?? const <String>[]) {
      result.add(
        serialDevice(
          portName,
          description: '',
          vendorId: null,
          productId: null,
          serialNumber: null,
        ),
      );
    }
    return result;
  }

  @override
  bool includeDevice(FlipperDevice device) {
    const flipperVid = 0x0483;
    const flipperPid = 0x5740;
    if (device.vendorId == flipperVid && device.productId == flipperPid) {
      return true;
    }

    final haystack = [
      device.id,
      device.name,
      device.serialNumber ?? '',
    ].join(' ').toLowerCase();
    return haystack.contains('usbmodem') ||
        haystack.contains('usbserial') ||
        haystack.contains('flipper') ||
        haystack.contains('flip_') ||
        haystack.contains('stm32') ||
        haystack.contains('stmicroelectronics') ||
        haystack.contains('virtual com');
  }

  @override
  Future<_Transport> openTransport(UsbDiscoveredDevice device) {
    if (device is! DesktopUsbDiscoveredDevice) {
      throw UnsupportedError('macOS USB transport requires serial device');
    }
    return _MacosUsbTransport.create(device);
  }
}

class _MacosUsbTransport extends _SerialUsbTransportBase {
  _MacosUsbTransport._(
    super.isolate,
    super.eventPort,
    super.events,
    super.commandPort,
  );

  static Future<_MacosUsbTransport> create(DesktopUsbDiscoveredDevice device) {
    return _SerialUsbTransportBase.createFor(device, _MacosUsbTransport._);
  }
}
