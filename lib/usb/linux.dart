part of '../flipper_client.dart';

class _LinuxUsbPlatform extends _SerialUsbPlatformBase {
  const _LinuxUsbPlatform();

  @override
  Future<List<FlipperDevice>> loadDevices() async {
    final result = <FlipperDevice>[];
    final availablePorts = _readSerialProperty(() => SerialPort.availablePorts);
    for (final portName in availablePorts ?? const <String>[]) {
      final port = SerialPort(portName);
      try {
        final description = metadataDescription(port);
        final vendorId = metadataVendorId(port);
        final productId = metadataProductId(port);
        final serialNumber = metadataSerialNumber(port);
        result.add(
          serialDevice(
            portName,
            description: description,
            vendorId: vendorId,
            productId: productId,
            serialNumber: serialNumber,
          ),
        );
      } finally {
        port.dispose();
      }
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

    final portName = device.id;
    if (portName.startsWith('/dev/ttyACM') ||
        portName.startsWith('/dev/ttyUSB')) {
      return true;
    }

    final haystack = [
      device.id,
      device.name,
      device.serialNumber ?? '',
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
    if (device is! DesktopUsbDiscoveredDevice) {
      throw UnsupportedError('Linux USB transport requires serial device');
    }
    return _LinuxUsbTransport.create(device);
  }
}

class _LinuxUsbTransport extends _SerialUsbTransportBase {
  _LinuxUsbTransport._(
    super.isolate,
    super.eventPort,
    super.events,
    super.commandPort,
  );

  static Future<_LinuxUsbTransport> create(DesktopUsbDiscoveredDevice device) {
    return _SerialUsbTransportBase.createFor(device, _LinuxUsbTransport._);
  }
}
