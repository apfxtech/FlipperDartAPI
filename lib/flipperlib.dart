export 'protobuf.dart';
export 'flipper_client.dart';
export 'discovered_device.dart';
export 'log_service.dart';

import 'flipper_client.dart';

class FlipperOneClient {
  static final FlipperOneClient _singleton = FlipperOneClient._internal();

  FlipperClient? _client;

  FlipperOneClient._internal();

  factory FlipperOneClient() => _singleton;

  FlipperClient get() {
    _client ??= FlipperClient();
    return _client!;
  }

  FlipperClient call() => get();
}
