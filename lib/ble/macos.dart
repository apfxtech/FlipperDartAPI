part of '../flipper_client.dart';

// Native macOS BLE adapter (FlipperBlePlugin via MethodChannel).
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
    // Defensive decoding: a malformed native event must not throw out of the
    // event-channel listener (an unhandled error there is pure noise and the
    // rest of the batch would be lost).
    final event = raw is Map<Object?, Object?> ? raw : null;
    final type = event?['type'];
    if (event == null || type is! String) {
      LogService.log('[BLE] macOS: unrecognized native event: $raw');
      return;
    }
    final deviceId = event['deviceId'];
    if (deviceId is! String) {
      LogService.log('[BLE] macOS: native event without deviceId: $type');
      return;
    }
    switch (type) {
      case 'connectionChange':
        final error = event['error'];
        final connected = event['connected'];
        ops._onConn?.call(
          deviceId,
          connected is bool ? connected : false,
          error is String ? error : null,
        );
      case 'valueChange':
        // FlutterStandardTypedData → Uint8List is decoded automatically by codec
        final value = event['value'];
        final bytes = value is Uint8List
            ? value
            : value is List
            ? Uint8List.fromList(value.cast<int>())
            : Uint8List(0);
        final charUuid = event['charUuid'];
        if (charUuid is! String) return;
        ops._onValue?.call(deviceId, charUuid, bytes, null);
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

class _MacosBlePlatform extends _UniversalBlePlatformBase {
  _MacosBlePlatform();

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
  Future<_Transport> openTransport(BleDiscoveredDevice device) {
    return _MacosBleTransport.create(device);
  }
}

class _MacosBleTransport extends _UniversalBleTransportBase {
  _MacosBleTransport._(BleDiscoveredDevice device)
    : super(device, _NativeMacosOps());

  static Future<_MacosBleTransport> create(BleDiscoveredDevice device) async {
    final transport = _MacosBleTransport._(device);
    // _configure releases the platform link itself if it fails.
    await transport._configure();
    // macOS auto-negotiates MTU. If the plugin reports the default payload,
    // fall back to the stable payload cap (see _maxBleMtuSize).
    if (transport._bleMtuSize < 100) {
      transport._bleMtuSize = _UniversalBleTransportBase._maxBleMtuSize;
      LogService.log(
        '[BLE] macOS: MTU not negotiated, using mtu=${transport._bleMtuSize}',
      );
    }
    return transport;
  }

  @override
  Future<void> _openExtra() async {
    // After all subscriptions are registered, pause before sending any RPC data.
    // This gives the Flipper firmware time to send an L2CAP Connection Parameter
    // Update Request; macOS accepts it and negotiates a shorter connection interval
    // (typically 15–30 ms vs the 100 ms macOS default).  btleplug uses the same
    // 300 ms settle for exactly this reason.  The pause is harmless — it is well
    // below the BLE supervision timeout and no GATT operations are in flight.
    await Future.delayed(const Duration(milliseconds: 300));
    LogService.log('[BLE] macOS: connection parameter settle complete');
  }
}
