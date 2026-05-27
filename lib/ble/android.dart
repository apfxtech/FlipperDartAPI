part of '../flipper_client.dart';

class _AndroidBlePlatform extends _UniversalBlePlatformBase {
  const _AndroidBlePlatform();

  @override
  Future<void> requestPermissions() async {
    try {
      await uble.UniversalBle.requestPermissions(withAndroidFineLocation: true);
    } catch (e) {
      LogService.log(
        '[FlipperClient] Android BLE permission request failed: $e',
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
    return _AndroidBleTransport.create(device);
  }
}

class _AndroidBleTransport extends _UniversalBleTransportBase {
  _AndroidBleTransport._(BleDiscoveredDevice device)
    : super(device, _UniversalBleOps());

  static Future<_AndroidBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _AndroidBleTransport._(device);
    await transport._configure();
    return transport;
  }
}
