part of '../flipper_client.dart';

class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    this.heading = 0,
    this.speed = 0,
    this.altitude = 0,
    this.accuracy = 0,
    this.satellites = 0,
  });

  factory GpsFix.fromLocation(Location location) => GpsFix(
        latitude: location.latitude / 1e7,
        longitude: location.longitude / 1e7,
        heading: location.heading / 100,
        speed: location.speed / 1000,
        altitude: location.altitude / 100,
        accuracy: location.accuracy / 1000,
        satellites: location.satellites,
      );

  final double latitude;
  final double longitude;
  final double heading;
  final double speed;
  final double altitude;
  final double accuracy;
  final int satellites;

  bool get hasFix => latitude != 0 || longitude != 0;
}

enum GpsReadiness {
  ready,
  notSupported,
  disabled,
  permissionDenied,
  unknown,
}

abstract class GpsLocationProvider {

  Future<GpsReadiness> ensureReady();

  Stream<GpsFix> watch(int frequencyHz);

  Future<GpsFix?> current();
}

class FlipperGpsResponder {
  FlipperGpsResponder(this._client, this._provider);

  static const int minFrequency = 1;
  static const int maxFrequency = 10;

  final FlipperClient _client;
  final GpsLocationProvider _provider;

  StreamSubscription<Main>? _notifications;
  StreamSubscription<FlipperConnectionState>? _connection;
  StreamSubscription<GpsFix>? _stream;
  int? _streamFrequency;
  void attach() {
    _notifications ??= _client.notificationStream.listen(_onNotification);
    _connection ??= _client.connectionStream.listen(_onConnection);
  }
  Future<void> detach() async {
    await _stopStream();
    final notifications = _notifications;
    final connection = _connection;
    _notifications = null;
    _connection = null;
    await notifications?.cancel();
    await connection?.cancel();
  }

  void _onConnection(FlipperConnectionState state) {
    if (!state.connected || state.mode != FlipperMode.rpc) {
      unawaited(_stopStream());
    }
  }

  void _onNotification(Main frame) {
    if (frame.hasGpsStreamStartRequest()) {
      unawaited(_onStreamStart(frame.gpsStreamStartRequest.frequency));
    } else if (frame.hasGpsStreamStopRequest()) {
      unawaited(_stopStream());
    } else if (frame.hasGpsLocationRequest()) {
      unawaited(_onLocationRequest());
    }
  }

  Future<void> _onStreamStart(int frequency) async {
    final hz = frequency.clamp(minFrequency, maxFrequency);
    if (_stream != null && _streamFrequency == hz) return;
    if (!await _ensureReady()) return;
    await _stopStream();
    _streamFrequency = hz;
    _stream = _provider.watch(hz).listen(
      (fix) => unawaited(_sendLocation(fix)),
      onError: (Object error) =>
          LogService.log('[GPS] location stream error: $error'),
    );
  }

  Future<void> _onLocationRequest() async {
    if (!await _ensureReady()) return;
    final fix = await _provider.current();
    if (fix != null) await _sendLocation(fix);
  }

  Future<bool> _ensureReady() async {
    GpsReadiness readiness;
    try {
      readiness = await _provider.ensureReady();
    } catch (error) {
      LogService.log('[GPS] readiness check failed: $error');
      readiness = GpsReadiness.unknown;
    }
    switch (readiness) {
      case GpsReadiness.ready:
        return true;
      case GpsReadiness.notSupported:
        await _sendError(CommandStatus.ERROR_GPS_NOT_SUPPORTED);
        return false;
      case GpsReadiness.disabled:
        await _sendError(CommandStatus.ERROR_GPS_DISABLED);
        return false;
      case GpsReadiness.permissionDenied:
        await _sendError(CommandStatus.ERROR_GPS_NO_PERMISSION);
        return false;
      case GpsReadiness.unknown:
        await _sendError(CommandStatus.ERROR_GPS_UNKNOWN);
        return false;
    }
  }

  Future<void> _stopStream() async {
    _streamFrequency = null;
    final sub = _stream;
    _stream = null;
    await sub?.cancel();
  }
  static int _scaleUnsigned(double value, double factor) =>
      value.isFinite && value > 0 ? (value * factor).round() : 0;

  Future<void> _sendLocation(GpsFix fix) async {
    final location = Location(
      latitude: (fix.latitude * 1e7).round(),
      longitude: (fix.longitude * 1e7).round(),
      altitude: (fix.altitude * 100).round(),
      speed: _scaleUnsigned(fix.speed, 1000),
      heading: _scaleUnsigned(fix.heading, 100),
      accuracy: _scaleUnsigned(fix.accuracy, 1000),
      satellites: fix.satellites,
    );
    try {
      await _client.sendRpc(
        Main(gpsLocation: location),
        priority: FlipperRequestPriority.background,
      );
    } catch (error) {
      LogService.log('[GPS] failed to send location: $error');
    }
  }

  Future<void> _sendError(CommandStatus status) async {
    try {
      await _client.sendRpc(
        Main(commandStatus: status, gpsLocation: Location()),
      );
    } catch (error) {
      LogService.log('[GPS] failed to send error ${status.name}: $error');
    }
  }
}

extension FlipperGpsApi on FlipperClient {
  FlipperGpsResponder attachGpsResponder(GpsLocationProvider provider) {
    final responder = FlipperGpsResponder(this, provider);
    responder.attach();
    return responder;
  }

  Stream<GpsFix> flipperLocationStream() {
    return notificationStream.transform(
      StreamTransformer<Main, GpsFix>.fromHandlers(
        handleData: (frame, sink) {
          if (frame.hasGpsLocation()) {
            sink.add(GpsFix.fromLocation(frame.gpsLocation));
          }
        },
      ),
    );
  }
}
