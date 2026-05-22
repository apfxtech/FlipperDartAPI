part of '../flipper_client.dart';

class _MacosBlePlatform extends _UniversalBlePlatformBase {
  _MacosBlePlatform();

  final Set<String> _verifiedDeviceIds = <String>{};
  final Set<String> _rejectedProbeIds = <String>{};

  @override
  Iterable<uble.ScanFilter?> get scanFilters => [
    uble.ScanFilter(withServices: const [FlipperClient.bleServiceUuid]),
    null,
  ];

  @override
  Future<void> requestPermissions() async {
    try {
      await uble.UniversalBle.requestPermissions();
    } catch (e) {
      LogService.log('[FlipperClient] macOS BLE permission request failed: $e');
    }
  }

  @override
  Future<List<BleDiscoveredDevice>> loadKnownDevices() async {
    try {
      final devices = await uble.UniversalBle.getSystemDevices(
        withServices: const [FlipperClient.bleServiceUuid],
      );
      return devices
          .map(BleDiscoveredDevice.new)
          .where(includeDevice)
          .toList(growable: false);
    } catch (e) {
      LogService.log('[FlipperClient] known BLE devices lookup failed: $e');
      return const <BleDiscoveredDevice>[];
    }
  }

  @override
  bool includeDevice(BleDiscoveredDevice device) {
    if (_verifiedDeviceIds.contains(device.id)) return true;

    final services = device.device.services.map((uuid) => uuid.toLowerCase());
    if (_hasFlipperService(services)) return true;

    if (_hasFlipperService(device.device.serviceData.keys)) return true;

    final name = device.name.toLowerCase();
    return name.contains('flipper') || name.contains('flip_');
  }

  @override
  Future<List<BleDiscoveredDevice>> resolveScanResults(
    Iterable<BleDiscoveredDevice> devices,
  ) async {
    final candidates = <BleDiscoveredDevice>[];
    final seen = <String>{};
    for (final device in devices) {
      if (includeDevice(device)) continue;
      if (_rejectedProbeIds.contains(device.id)) continue;
      if (!seen.add(device.id)) continue;
      if (!_shouldProbe(device)) continue;
      candidates.add(device);
    }

    candidates.sort((a, b) => b.rssi.compareTo(a.rssi));
    final resolved = <BleDiscoveredDevice>[];
    for (final device in candidates.take(8)) {
      if (await _probeFlipperService(device)) {
        _verifiedDeviceIds.add(device.id);
        resolved.add(device);
      } else {
        _rejectedProbeIds.add(device.id);
      }
    }
    return resolved;
  }

  bool _shouldProbe(BleDiscoveredDevice device) {
    if (device.device.services.isNotEmpty) return true;
    final name = device.name;
    return name == device.id || _looksLikeApplePeripheralId(name);
  }

  bool _looksLikeApplePeripheralId(String value) {
    return RegExp(
      r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
    ).hasMatch(value);
  }

  bool _hasFlipperService(Iterable<String> services) {
    return services
        .map((uuid) => uuid.toLowerCase())
        .contains(FlipperClient.bleServiceUuid);
  }

  Future<bool> _probeFlipperService(BleDiscoveredDevice device) async {
    try {
      LogService.log('[BLE] macOS probe ${device.id} name=${device.name}');
      await uble.UniversalBle.connect(
        device.device.deviceId,
        timeout: const Duration(seconds: 4),
      );
      final services = await uble.UniversalBle.discoverServices(
        device.device.deviceId,
      );
      final hasFlipper = _hasFlipperService(services.map((s) => s.uuid));
      LogService.log(
        '[BLE] macOS probe result ${device.id} '
        'services=${services.map((s) => s.uuid).toList()} '
        'flipper=$hasFlipper',
      );
      return hasFlipper;
    } catch (e) {
      LogService.log('[BLE] macOS probe failed ${device.id}: $e');
      return false;
    } finally {
      try {
        await uble.UniversalBle.disconnect(device.device.deviceId);
      } catch (_) {}
    }
  }

  @override
  Future<_Transport> openTransport(BleDiscoveredDevice device) {
    return _MacosBleTransport.create(device);
  }
}

class _MacosBleTransport extends _UniversalBleTransportBase {
  _MacosBleTransport._(super.device);

  static Future<_MacosBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _MacosBleTransport._(device);
    await transport._configure();
    return transport;
  }
}
