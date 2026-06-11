part of '../flipper_client.dart';

class _IosUsbPlatform extends _UsbPlatform {
  const _IosUsbPlatform();

  @override
  Future<List<FlipperDevice>> loadDevices() async {
    return const <FlipperDevice>[];
  }

  @override
  Future<_Transport> openTransport(UsbDiscoveredDevice device) {
    throw UnsupportedError('USB transport is not available on iOS');
  }
}
