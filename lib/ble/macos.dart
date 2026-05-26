part of '../flipper_client.dart';

class _MacosBlePlatform extends _UniversalBlePlatformBase {
  _MacosBlePlatform();

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
    final services = device.device.services.map((uuid) => uuid.toLowerCase());
    if (_hasFlipperService(services)) return true;

    if (_hasFlipperService(device.device.serviceData.keys)) return true;

    final name = device.name.toLowerCase();
    return name.contains('flipper') || name.contains('flip_');
  }

  bool _hasFlipperService(Iterable<String> services) {
    return services
        .map((uuid) => uuid.toLowerCase())
        .contains(FlipperClient.bleServiceUuid);
  }

  @override
  Future<_Transport> openTransport(BleDiscoveredDevice device) {
    return _MacosBleTransport.create(device);
  }
}

class _MacosBleTransport extends _UniversalBleTransportBase {
  _MacosBleTransport._(super.device);

  bool _wasAlreadyConnected = false;

  static Future<_MacosBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _MacosBleTransport._(device);
    await transport._configure();
    // CoreBluetooth negotiates MTU automatically; requestMtu() returns 23 on macOS.
    // Use a safe default that works without explicit negotiation.
    if (transport._bleChunkSize < 100) {
      transport._bleChunkSize = 182;
      LogService.log('[BLE] macOS: MTU not negotiated, using chunk=182');
    }
    return transport;
  }

  // Fix 1: on macOS, calling connect() on an already-connected peripheral
  // waits indefinitely for a DidConnect callback that never fires.
  @override
  Future<void> _connectDevice() async {
    uble.BleConnectionState? state;
    try {
      state = await uble.UniversalBle.getConnectionState(_device.device.deviceId)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // If the check hangs or fails, fall through to connect() as normal.
    }
    if (state == uble.BleConnectionState.connected) {
      LogService.log('[BLE] macOS: peripheral already connected, skipping connect()');
      _wasAlreadyConnected = true;
      return;
    }
    await uble.UniversalBle.connect(_device.device.deviceId);
  }

  // Skip the settle delay when the peripheral was already connected — the link
  // is stable and CoreBluetooth does not need time to negotiate parameters.
  @override
  Future<void> _postConnectDelay() =>
      _wasAlreadyConnected
          ? Future.value()
          : Future.delayed(const Duration(milliseconds: 600));

  // Fix 2: subscribe to rpcStatus so firmware auto-starts RPC session.
  @override
  Future<void> _openExtra() async {
    final svc = _rpcStatusSvcId;
    final chr = _rpcStatusCharId;
    if (svc == null || chr == null) return;
    try {
      await uble.UniversalBle.subscribeNotifications(
        _device.device.deviceId,
        svc,
        chr,
      ).timeout(const Duration(seconds: 4));
      LogService.log('[BLE] macOS: subscribed to rpcStatus');
    } catch (e) {
      LogService.log('[BLE] macOS: rpcStatus subscribe failed (non-fatal): $e');
    }
  }

  // Fix 3: writing to rpcStatus on macOS CoreBluetooth triggers an ATT error
  // that tears the whole connection down.
  @override
  bool get _canWriteRpcStatus => false;
}
