part of '../flipper_client.dart';

class _WindowsUsbPlatform extends _SerialUsbPlatformBase {
  const _WindowsUsbPlatform();

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
  Future<_Transport> openTransport(UsbDiscoveredDevice device) {
    if (device is! DesktopUsbDiscoveredDevice) {
      throw UnsupportedError('Windows USB transport requires serial device');
    }
    return _WindowsUsbTransport.create(device);
  }
}

class _WindowsUsbTransport extends _SerialUsbTransportBase {
  _WindowsUsbTransport._(
    super.isolate,
    super.eventPort,
    super.events,
    super.commandPort,
  );

  static Future<_WindowsUsbTransport> create(
    DesktopUsbDiscoveredDevice device,
  ) {
    return _SerialUsbTransportBase.createFor(device, _WindowsUsbTransport._);
  }
}
