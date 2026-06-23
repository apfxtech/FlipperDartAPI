part of '../flipper_client.dart';

class _NetworkConnection {
  _NetworkConnection(this.id, this.protocol);

  final int id;
  final Protocol protocol;

  Socket? tcp;
  RawDatagramSocket? udp;
  InternetAddress? udpRemote;
  int udpPort = 0;
  StreamSubscription<dynamic>? subscription;
  bool closed = false;
}

class FlipperNetworkResponder {
  FlipperNetworkResponder(this._client);

  static const int maxConnections = 8;
  static const int maxChunkSize = 512;
  static const Duration _defaultTimeout = Duration(seconds: 30);

  final FlipperClient _client;
  final Map<int, _NetworkConnection> _connections = {};

  StreamSubscription<Main>? _notifications;
  StreamSubscription<FlipperConnectionState>? _connection;

  void attach() {
    _notifications ??= _client.notificationStream.listen(_onNotification);
    _connection ??= _client.connectionStream.listen(_onConnection);
  }

  Future<void> detach() async {
    final notifications = _notifications;
    final connection = _connection;
    _notifications = null;
    _connection = null;
    await notifications?.cancel();
    await connection?.cancel();
    await _closeAll();
  }

  void _onConnection(FlipperConnectionState state) {
    if (!state.connected || state.mode != FlipperMode.rpc) {
      unawaited(_closeAll());
    }
  }

  void _onNotification(Main frame) {
    if (frame.hasNetworkConnectRequest()) {
      unawaited(_onConnect(frame.networkConnectRequest));
    } else if (frame.hasNetworkSendRequest()) {
      unawaited(_onSend(frame.networkSendRequest));
    } else if (frame.hasNetworkCloseRequest()) {
      unawaited(_onClose(frame.networkCloseRequest));
    }
  }

  Future<void> _onConnect(ConnectRequest request) async {
    final id = request.connectionId;
    if (_connections.containsKey(id)) {
      await _sendConnectError(id, ErrorCode.INVALID_CONNECTION);
      return;
    }
    if (_connections.length >= maxConnections) {
      await _sendConnectError(id, ErrorCode.MAX_CONNECTIONS);
      return;
    }
    if (request.host.isEmpty || request.port == 0 || request.port > 65535) {
      await _sendConnectError(id, ErrorCode.INTERNAL_ERROR);
      return;
    }

    final timeout = request.timeoutMs > 0
        ? Duration(milliseconds: request.timeoutMs)
        : _defaultTimeout;

    if (request.protocol == Protocol.UDP) {
      await _openUdp(id, request, timeout);
    } else {
      await _openTcp(id, request, timeout);
    }
  }

  Future<void> _openTcp(
    int id,
    ConnectRequest request,
    Duration timeout,
  ) async {
    final connection = _NetworkConnection(id, Protocol.TCP);
    _connections[id] = connection;
    try {
      final socket = await Socket.connect(
        request.host,
        request.port,
        timeout: timeout,
      );
      if (connection.closed) {
        socket.destroy();
        return;
      }
      connection.tcp = socket;
      connection.subscription = socket.listen(
        (data) => _onReceived(id, data),
        onError: (Object error) => _onSocketError(id, error),
        onDone: () => _onSocketDone(id),
        cancelOnError: true,
      );
      await _sendConnectSuccess(id, socket.remoteAddress.address);
    } catch (error) {
      _connections.remove(id);
      await _sendConnectError(id, _errorFor(error));
    }
  }

  Future<void> _openUdp(
    int id,
    ConnectRequest request,
    Duration timeout,
  ) async {
    final connection = _NetworkConnection(id, Protocol.UDP);
    _connections[id] = connection;
    try {
      final addresses = await InternetAddress.lookup(request.host)
          .timeout(timeout);
      if (addresses.isEmpty) {
        _connections.remove(id);
        await _sendConnectError(id, ErrorCode.DNS_FAILED);
        return;
      }
      final remote = addresses.first;
      final socket = await RawDatagramSocket.bind(
        remote.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
      if (connection.closed) {
        socket.close();
        return;
      }
      connection.udp = socket;
      connection.udpRemote = remote;
      connection.udpPort = request.port;
      connection.subscription = socket.listen(
        (event) => _onUdpEvent(id, event),
        onError: (Object error) => _onSocketError(id, error),
        onDone: () => _onSocketDone(id),
      );
      await _sendConnectSuccess(id, remote.address);
    } catch (error) {
      _connections.remove(id);
      await _sendConnectError(id, _errorFor(error));
    }
  }

  Future<void> _onSend(SendRequest request) async {
    final id = request.connectionId;
    final connection = _connections[id];
    if (connection == null || connection.closed) {
      await _sendSendResponse(id, 0, ErrorCode.NOT_CONNECTED);
      return;
    }
    final data = request.data;
    try {
      if (connection.protocol == Protocol.UDP) {
        final socket = connection.udp;
        if (socket == null) {
          await _sendSendResponse(id, 0, ErrorCode.NOT_CONNECTED);
          return;
        }
        final sent = socket.send(
          data,
          connection.udpRemote!,
          connection.udpPort,
        );
        await _sendSendResponse(id, sent, ErrorCode.NONE);
      } else {
        final socket = connection.tcp;
        if (socket == null) {
          await _sendSendResponse(id, 0, ErrorCode.NOT_CONNECTED);
          return;
        }
        socket.add(data);
        await socket.flush();
        await _sendSendResponse(id, data.length, ErrorCode.NONE);
      }
    } catch (error) {
      LogService.log('[Network] send failed on $id: $error');
      await _sendSendResponse(id, 0, ErrorCode.SEND_FAILED);
    }
  }

  Future<void> _onClose(CloseRequest request) async {
    final id = request.connectionId;
    final connection = _connections.remove(id);
    if (connection == null) {
      await _sendCloseResponse(id, ErrorCode.INVALID_CONNECTION);
      return;
    }
    await _teardown(connection);
    await _sendCloseResponse(id, ErrorCode.NONE);
  }

  void _onReceived(int id, List<int> data) {
    for (var offset = 0; offset < data.length; offset += maxChunkSize) {
      final remaining = data.length - offset;
      final end = offset + (remaining < maxChunkSize ? remaining : maxChunkSize);
      unawaited(_sendReceiveData(id, data.sublist(offset, end)));
    }
  }

  void _onUdpEvent(int id, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final connection = _connections[id];
    final datagram = connection?.udp?.receive();
    if (datagram == null) return;
    _onReceived(id, datagram.data);
  }

  void _onSocketError(int id, Object error) {
    LogService.log('[Network] socket error on $id: $error');
    final connection = _connections.remove(id);
    if (connection != null) {
      unawaited(_teardown(connection));
    }
    unawaited(_sendStateChanged(id, ConnectionState.ERROR, _errorFor(error)));
  }

  void _onSocketDone(int id) {
    final connection = _connections.remove(id);
    if (connection == null) return;
    unawaited(_teardown(connection));
    unawaited(
      _sendStateChanged(id, ConnectionState.DISCONNECTED, ErrorCode.NONE),
    );
  }

  Future<void> _teardown(_NetworkConnection connection) async {
    connection.closed = true;
    await connection.subscription?.cancel();
    connection.subscription = null;
    try {
      connection.tcp?.destroy();
      connection.udp?.close();
    } catch (error) {
      LogService.log('[Network] teardown error on ${connection.id}: $error');
    }
  }

  Future<void> _closeAll() async {
    final connections = _connections.values.toList();
    _connections.clear();
    for (final connection in connections) {
      await _teardown(connection);
    }
  }

  static ErrorCode _errorFor(Object error) {
    if (error is TimeoutException) return ErrorCode.TIMEOUT;
    if (error is SocketException) {
      final osError = error.osError;
      if (osError == null) {
        return error.message.contains('Failed host lookup')
            ? ErrorCode.DNS_FAILED
            : ErrorCode.INTERNAL_ERROR;
      }
      switch (osError.errorCode) {
        case 61:
        case 111:
          return ErrorCode.CONNECTION_REFUSED;
        case 60:
        case 110:
          return ErrorCode.TIMEOUT;
        case 65:
        case 113:
          return ErrorCode.HOST_UNREACHABLE;
        case 51:
        case 101:
          return ErrorCode.NETWORK_UNREACHABLE;
        case 8:
        case -2:
          return ErrorCode.DNS_FAILED;
        default:
          return ErrorCode.INTERNAL_ERROR;
      }
    }
    return ErrorCode.INTERNAL_ERROR;
  }

  Future<void> _sendConnectSuccess(int id, String resolvedIp) {
    return _send(
      Main(
        networkConnectResponse: ConnectResponse(
          connectionId: id,
          state: ConnectionState.CONNECTED,
          error: ErrorCode.NONE,
          resolvedIp: resolvedIp,
        ),
      ),
    );
  }

  Future<void> _sendConnectError(int id, ErrorCode error) {
    return _send(
      Main(
        networkConnectResponse: ConnectResponse(
          connectionId: id,
          state: ConnectionState.ERROR,
          error: error,
        ),
      ),
    );
  }

  Future<void> _sendSendResponse(int id, int bytesSent, ErrorCode error) {
    return _send(
      Main(
        networkSendResponse: SendResponse(
          connectionId: id,
          bytesSent: bytesSent,
          error: error,
        ),
      ),
    );
  }

  Future<void> _sendReceiveData(int id, List<int> data) {
    return _send(
      Main(
        networkReceiveData: ReceiveData(connectionId: id, data: data),
      ),
      priority: FlipperRequestPriority.background,
    );
  }

  Future<void> _sendCloseResponse(int id, ErrorCode error) {
    return _send(
      Main(
        networkCloseResponse: CloseResponse(connectionId: id, error: error),
      ),
    );
  }

  Future<void> _sendStateChanged(
    int id,
    ConnectionState state,
    ErrorCode error,
  ) {
    return _send(
      Main(
        networkStateChanged: StateChanged(
          connectionId: id,
          state: state,
          error: error,
        ),
      ),
    );
  }

  Future<void> _send(
    Main message, {
    FlipperRequestPriority priority = FlipperRequestPriority.defaultPriority,
  }) async {
    try {
      await _client.sendRpc(message, priority: priority);
    } catch (error) {
      LogService.log('[Network] failed to send response: $error');
    }
  }
}

extension FlipperNetworkApi on FlipperClient {
  FlipperNetworkResponder attachNetworkResponder() {
    final responder = FlipperNetworkResponder(this);
    responder.attach();
    return responder;
  }
}
