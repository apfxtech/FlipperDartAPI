part of '../flipper_client.dart';

// ── Native macOS BLE adapter (uses FlipperBlePlugin via MethodChannel) ───────

class _NativeMacosOps implements _BleOps {
  static const _mc = MethodChannel('com.qunleashed.flipper/ble');
  static const _ec = EventChannel('com.qunleashed.flipper/ble/events');

  // Single active instance — only one BLE transport runs at a time
  static _NativeMacosOps? _instance;
  static StreamSubscription<dynamic>? _evSub;

  void Function(String, bool, String?)? _onConn;
  void Function(String, String, Uint8List, int?)? _onValue;

  _NativeMacosOps() {
    _instance = this;
    _evSub ??= _ec.receiveBroadcastStream().listen(_dispatch, onError: (_) {});
  }

  static void _dispatch(dynamic raw) {
    final ops = _instance;
    if (ops == null) return;
    final event = raw as Map<Object?, Object?>;
    final type = event['type'] as String;
    switch (type) {
      case 'connectionChange':
        final error = event['error'];
        ops._onConn?.call(
          event['deviceId'] as String,
          event['connected'] as bool,
          error is String ? error : null,
        );
      case 'valueChange':
        // FlutterStandardTypedData → Uint8List is decoded automatically by codec
        final raw = event['value'];
        final bytes = raw is Uint8List
            ? raw
            : raw is List
            ? Uint8List.fromList(raw.cast<int>())
            : Uint8List(0);
        ops._onValue?.call(
          event['deviceId'] as String,
          event['charUuid'] as String,
          bytes,
          null,
        );
    }
  }

  @override
  set onConnectionChange(void Function(String, bool, String?)? cb) =>
      _onConn = cb;

  @override
  set onValueChange(void Function(String, String, Uint8List, int?)? cb) =>
      _onValue = cb;

  @override
  Future<void> connect(String deviceId) =>
      _mc.invokeMethod('connect', {'deviceId': deviceId});

  @override
  Future<int> requestMtu(String deviceId, int mtu) async {
    final v = await _mc.invokeMethod<int>('requestMtu', {
      'deviceId': deviceId,
      'mtu': mtu,
    });
    return v ?? 23;
  }

  @override
  Future<List<_BleService>> discoverServices(String deviceId) async {
    final raw = await _mc.invokeMethod<List<dynamic>>('discoverServices', {
      'deviceId': deviceId,
    });
    return (raw ?? []).map((svc) {
      final s = svc as Map<Object?, Object?>;
      final chars = (s['characteristics'] as List<dynamic>).map((ch) {
        final c = ch as Map<Object?, Object?>;
        return _BleChar(
          c['uuid'] as String,
          canWrite: c['canWrite'] as bool? ?? false,
          canWriteNoRsp: c['canWriteNoRsp'] as bool? ?? false,
          canNotify: c['canNotify'] as bool? ?? false,
          canIndicate: c['canIndicate'] as bool? ?? false,
        );
      }).toList();
      return _BleService(s['uuid'] as String, chars);
    }).toList();
  }

  @override
  Future<void> subscribeNotifications(
    String deviceId,
    String svcId,
    String charId,
  ) => _mc.invokeMethod('subscribe', {
    'deviceId': deviceId,
    'serviceUuid': svcId,
    'charUuid': charId,
    'indication': false,
  });

  @override
  Future<void> subscribeIndications(
    String deviceId,
    String svcId,
    String charId,
  ) => _mc.invokeMethod('subscribe', {
    'deviceId': deviceId,
    'serviceUuid': svcId,
    'charUuid': charId,
    'indication': true,
  });

  @override
  Future<Uint8List> read(String deviceId, String svcId, String charId) async {
    final v = await _mc.invokeMethod<Uint8List>('read', {
      'deviceId': deviceId,
      'serviceUuid': svcId,
      'charUuid': charId,
    });
    return v ?? Uint8List(0);
  }

  @override
  Future<void> write(
    String deviceId,
    String svcId,
    String charId,
    Uint8List data, {
    bool withoutResponse = false,
  }) => _mc.invokeMethod('write', {
    'deviceId': deviceId,
    'serviceUuid': svcId,
    'charUuid': charId,
    'data': data,
    'withoutResponse': withoutResponse,
  });

  @override
  Future<void> disconnect(String deviceId) =>
      _mc.invokeMethod('disconnect', {'deviceId': deviceId});

  @override
  Future<_BleConnState?> getConnectionState(String deviceId) async {
    try {
      final s = await _mc.invokeMethod<String>('getConnectionState', {
        'deviceId': deviceId,
      });
      return switch (s) {
        'connected' => _BleConnState.connected,
        'connecting' => _BleConnState.connecting,
        _ => _BleConnState.disconnected,
      };
    } catch (_) {
      return null;
    }
  }
}

// ── macOS BLE platform ────────────────────────────────────────────────────────

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

// ── macOS BLE transport ───────────────────────────────────────────────────────

class _MacosBleTransport extends _UniversalBleTransportBase {
  _MacosBleTransport._(BleDiscoveredDevice device)
    : super(device, _NativeMacosOps());

  static Future<_MacosBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _MacosBleTransport._(device);
    await transport._configure();
    // macOS auto-negotiates MTU; if the native plugin returned a suspiciously
    // small value (e.g. peripheral was connected before discovery), fall back
    // to 182 which is the typical negotiated limit on modern hardware.
    if (transport._bleChunkSize < 100) {
      transport._bleChunkSize = 182;
      LogService.log('[BLE] macOS: MTU not negotiated, using chunk=182');
    }
    return transport;
  }

  @override
  bool _txUsesWriteWithResponse(_BleChar char) {
    if (char.canWriteNoRsp) return false;
    return char.canWrite;
  }

  // Fix: subscribe to rpcStatus so firmware auto-starts RPC session on macOS.
  @override
  Future<void> _openExtra() async {
    final svc = _rpcStatusSvcId;
    final chr = _rpcStatusCharId;
    if (svc == null || chr == null) return;
    try {
      await _ops
          .subscribeNotifications(_device.device.deviceId, svc, chr)
          .timeout(const Duration(seconds: 4));
      LogService.log('[BLE] macOS: subscribed to rpcStatus');
    } catch (e) {
      LogService.log('[BLE] macOS: rpcStatus subscribe failed (non-fatal): $e');
    }
  }

  // Writing to rpcStatus on macOS triggers an ATT error that drops the link.
  @override
  bool get _canWriteRpcStatus => false;
}
