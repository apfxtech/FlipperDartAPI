part of '../flipper_client.dart';

enum NetworkDirection { tx, rx }

class NetworkTrafficSnapshot {
  const NetworkTrafficSnapshot({
    this.txBytes = 0,
    this.rxBytes = 0,
    this.host,
    this.activeConnections = 0,
    this.lastDirection,
    this.sequence = 0,
  });

  /// Total bytes the device pushed out to the internet (uplink).
  final int txBytes;

  /// Total bytes pulled from the internet back to the device (downlink).
  final int rxBytes;

  /// Domain currently or most recently exchanging data.
  final String? host;

  /// Number of live proxied connections.
  final int activeConnections;

  /// Direction of the most recent byte movement, for UI activity hints.
  final NetworkDirection? lastDirection;

  /// Monotonic counter bumped on every update, so identical byte totals still
  /// produce a distinct snapshot the UI can react to.
  final int sequence;

  bool get isActive => activeConnections > 0;
}

/// Live counters for the internet traffic the phone proxies on the Flipper's
/// behalf. Updated by [FlipperNetworkResponder]; observed by the UI.
class NetworkTrafficMonitor {
  NetworkTrafficMonitor._();

  static final NetworkTrafficMonitor instance = NetworkTrafficMonitor._();

  final ValueNotifier<NetworkTrafficSnapshot> snapshot = ValueNotifier(
    const NetworkTrafficSnapshot(),
  );

  int _tx = 0;
  int _rx = 0;
  String? _host;
  int _active = 0;
  int _seq = 0;

  void connectionOpened([String? host]) {
    _active++;
    if (host != null && host.isNotEmpty) _host = host;
    _emit(null);
  }

  void connectionClosed() {
    if (_active > 0) _active--;
    _emit(null);
  }

  void hostUpdated(String host) {
    if (host.isEmpty || host == _host) return;
    _host = host;
    _emit(null);
  }

  void recordTx(int bytes, {String? host}) {
    if (bytes <= 0) return;
    _tx += bytes;
    if (host != null && host.isNotEmpty) _host = host;
    _emit(NetworkDirection.tx);
  }

  void recordRx(int bytes) {
    if (bytes <= 0) return;
    _rx += bytes;
    _emit(NetworkDirection.rx);
  }

  void reset() {
    _tx = 0;
    _rx = 0;
    _host = null;
    _active = 0;
    snapshot.value = const NetworkTrafficSnapshot();
  }

  void _emit(NetworkDirection? direction) {
    snapshot.value = NetworkTrafficSnapshot(
      txBytes: _tx,
      rxBytes: _rx,
      host: _host,
      activeConnections: _active,
      lastDirection: direction,
      sequence: ++_seq,
    );
  }
}
