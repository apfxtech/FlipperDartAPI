part of '../flipper_client.dart';

final _BlePlatform _blePlatform = _createBlePlatform();

_BlePlatform _createBlePlatform() {
  if (Platform.isAndroid) return const _AndroidBlePlatform();
  if (Platform.isIOS) return const _IosBlePlatform();
  if (Platform.isLinux) return const _LinuxBlePlatform();
  if (Platform.isMacOS) return _MacosBlePlatform();
  if (Platform.isWindows) return const _WindowsBlePlatform();
  return const _UnsupportedBlePlatform();
}

class _UnsupportedBlePlatform extends _UniversalBlePlatformBase {
  const _UnsupportedBlePlatform();

  @override
  Future<void> requestPermissions() async {}

  @override
  bool includeDevice(BleDiscoveredDevice device) => false;

  @override
  Future<_Transport> openTransport(BleDiscoveredDevice device) {
    throw UnsupportedError('BLE transport is not available on this platform');
  }
}

extension FlipperBleApi on FlipperClient {
  Stream<FlipperDevice> get bleDevicesStream => devicesStream.asyncExpand(
    (devices) => Stream.fromIterable(devices.where((device) => device.isBle)),
  );
}
