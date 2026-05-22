part of 'flipper_client.dart';

final _UsbPlatform _usbPlatform = _createUsbPlatform();

_UsbPlatform _createUsbPlatform() {
  if (Platform.isAndroid) return const _AndroidUsbPlatform();
  if (Platform.isIOS) return const _IosUsbPlatform();
  if (Platform.isLinux) return const _LinuxUsbPlatform();
  if (Platform.isMacOS) return const _MacosUsbPlatform();
  if (Platform.isWindows) return const _WindowsUsbPlatform();
  return const _UnsupportedUsbPlatform();
}

class _UnsupportedUsbPlatform implements _UsbPlatform {
  const _UnsupportedUsbPlatform();

  @override
  Future<List<FlipperDevice>> loadDevices() async {
    return const <FlipperDevice>[];
  }

  @override
  bool includeDevice(FlipperDevice device) => false;

  @override
  Future<_Transport> openTransport(UsbDiscoveredDevice device) {
    throw UnsupportedError('USB transport is not available on this platform');
  }
}

extension FlipperUsbApi on FlipperClient {
  Stream<FlipperDevice> get usbDevicesStream => devicesStream.asyncExpand(
    (devices) => Stream.fromIterable(devices.where((device) => device.isUsb)),
  );
}
