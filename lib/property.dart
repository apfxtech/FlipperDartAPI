part of 'flipper_client.dart';

extension FlipperPropertyApi on FlipperClient {
  Future<FlipperRpcBatch<GetResponse>> propertyGet(
    GetRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(propertyGetRequest: request),
      (frame) =>
          frame.hasPropertyGetResponse() ? frame.propertyGetResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }
}
