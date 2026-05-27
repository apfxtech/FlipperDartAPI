part of '../flipper_client.dart';

class _WindowsBlePlatform extends _UniversalBlePlatformBase {
  const _WindowsBlePlatform();

  @override
  Future<void> requestPermissions() async {
    try {
      await uble.UniversalBle.requestPermissions();
    } catch (e) {
      LogService.log(
        '[FlipperClient] Windows BLE permission request failed: $e',
      );
    }
  }

  @override
  bool includeDevice(BleDiscoveredDevice device) {
    final id = device.id.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (id.startsWith('80E127') || id.startsWith('80E126')) return true;

    final name = device.name.toLowerCase();
    return name.contains('flipper') || name.contains('flip_');
  }

  @override
  Future<_Transport> openTransport(BleDiscoveredDevice device) {
    return _WindowsBleTransport.create(device);
  }
}

class _WindowsBleTransport extends _UniversalBleTransportBase {
  _WindowsBleTransport._(BleDiscoveredDevice device)
    : super(device, _UniversalBleOps());

  static Future<_WindowsBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _WindowsBleTransport._(device);
    await transport._configure();
    return transport;
  }
}
