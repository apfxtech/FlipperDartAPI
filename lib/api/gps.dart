part of '../flipper_client.dart';

/// A single location sample taken from the host platform.
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

  final double latitude;
  final double longitude;
  final double heading;
  final double speed;
  final double altitude;
  final double accuracy;
  final int satellites;
}

/// Platform location source. The host app supplies a concrete implementation
/// (e.g. backed by geolocator); flipperlib stays platform-agnostic.
abstract class GpsLocationProvider {
  /// Whether this device can report location at all.
  bool get isSupported;

  /// Requests/checks location permission. Returns true when granted.
  Future<bool> ensurePermission();

  /// Continuous location updates at roughly [frequencyHz] samples per second.
  Stream<GpsFix> watch(int frequencyHz);

  /// A single current location, or null when it can't be determined.
  Future<GpsFix?> current();
}

/// Answers the Flipper's GPS requests with the phone's location.
///
/// A custom firmware app pushes StreamStart / StreamStop / Location requests as
/// command_id == 0 broadcasts; this responder turns them into [Location]
/// packets sent back through the normal RPC queue and flow control, or replies
/// with an error status when the device has no location capability/permission.
class FlipperGpsResponder {
  FlipperGpsResponder(this._client, this._provider);

  static const int minFrequency = 1;
  static const int maxFrequency = 10;

  final FlipperClient _client;
  final GpsLocationProvider _provider;

  StreamSubscription<Main>? _notifications;
  StreamSubscription<FlipperConnectionState>? _connection;
  StreamSubscription<GpsFix>? _stream;

  /// Starts listening for GPS requests. Idempotent.
  void attach() {
    _notifications ??= _client.notificationStream.listen(_onNotification);
    // A dropped link means the Flipper's stream request is gone; stop pushing
    // into a dead session instead of burning the phone's GPS forever.
    _connection ??= _client.connectionStream.listen(_onConnection);
  }

  /// Stops the responder and any active location stream.
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
    if (!await _ensureReady()) return;
    final hz = frequency.clamp(minFrequency, maxFrequency);
    await _stopStream();
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

  // Validates capability/permission once, sending the matching error status to
  // the Flipper when not satisfied. Returns true only when streaming may start.
  Future<bool> _ensureReady() async {
    if (!_provider.isSupported) {
      await _sendError(CommandStatus.ERROR_GPS_NOT_SUPPORTED);
      return false;
    }
    if (!await _provider.ensurePermission()) {
      await _sendError(CommandStatus.ERROR_GPS_NO_PERMISSION);
      return false;
    }
    return true;
  }

  Future<void> _stopStream() async {
    final sub = _stream;
    _stream = null;
    await sub?.cancel();
  }

  // Non-negative scaled integer, for the unsigned wire fields.
  static int _scaleUnsigned(double value, double factor) =>
      value.isFinite && value > 0 ? (value * factor).round() : 0;

  Future<void> _sendLocation(GpsFix fix) async {
    // Wire fields are integer fixed-point (see gps.proto): degrees*1e7,
    // centimeters, mm/s, degrees*100, millimeters.
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
      // The link is gone; stop the stream rather than retrying every tick.
      LogService.log('[GPS] failed to send location, stopping stream: $error');
      await _stopStream();
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
  /// Attaches a [FlipperGpsResponder] that answers the Flipper's GPS requests
  /// using [provider]. The caller owns the returned responder and should call
  /// `detach()` when done.
  FlipperGpsResponder attachGpsResponder(GpsLocationProvider provider) {
    final responder = FlipperGpsResponder(this, provider);
    responder.attach();
    return responder;
  }
}
