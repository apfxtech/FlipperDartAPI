part of 'flipper_client.dart';

extension FlipperUsbApi on FlipperClient {
  Stream<FlipperDevice> get usbDevicesStream => devicesStream.asyncExpand(
        (devices) => Stream.fromIterable(
          devices.where((device) => device.isUsb),
        ),
      );
}

class _AndroidUsbTransport extends _Transport {
  final UsbPort _port;
  StreamSubscription<Uint8List>? _inputSub;

  _AndroidUsbTransport._(this._port);

  static Future<_AndroidUsbTransport> create(
    AndroidUsbDiscoveredDevice device,
  ) async {
    final port = await device.usbDevice.create();
    if (port == null) {
      throw StateError('USB permission denied or port unavailable');
    }
    final opened = await port.open();
    if (!opened) {
      throw StateError('Failed to open USB port');
    }
    await port.setPortParameters(
      230400,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    return _AndroidUsbTransport._(port);
  }

  @override
  bool get supportsCli => true;

  @override
  FlipperMode get initialMode => FlipperMode.cli;

  @override
  int get storageChunkSize => 1024;

  @override
  Future<void> open() async {
    _inputSub = _port.inputStream?.listen(
      addBytes,
      onError: (Object error, StackTrace stackTrace) {
        LogService.log('[FlipperClient] Android USB read error: $error');
        onTransportFault(error);
      },
      onDone: () {
        onTransportFault(StateError('USB input stream closed'));
      },
    );
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    await _port.write(bytes);
  }

  @override
  Future<void> nudgeCli() async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    await _port.setDTR(false);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await _port.setDTR(true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await writeAscii('\r');
  }

  @override
  Future<void> doClose() async {
    await _inputSub?.cancel();
    _inputSub = null;
    try {
      await _port.close();
    } catch (e) {
      LogService.log('[FlipperClient] Android USB close error: $e');
    }
  }
}

class _DesktopUsbTransport extends _Transport {
  final Isolate _isolate;
  final ReceivePort _eventPort;
  final Stream<dynamic> _events;
  final SendPort _commandPort;
  final Map<int, Completer<void>> _inFlight = {};
  final Completer<void> _exited = Completer<void>();
  StreamSubscription<dynamic>? _eventSub;
  int _writeSeq = 0;

  _DesktopUsbTransport._(
    this._isolate,
    this._eventPort,
    this._events,
    this._commandPort,
  );

  static Future<_DesktopUsbTransport> create(
    DesktopUsbDiscoveredDevice device,
  ) async {
    final eventPort = ReceivePort();
    final events = eventPort.asBroadcastStream();
    final boot = Completer<Object>();

    late StreamSubscription<dynamic> bootSub;
    bootSub = events.listen((message) {
      if (boot.isCompleted) return;
      if (message is DesktopUsbReady) {
        boot.complete(message);
      } else if (message is DesktopUsbFault) {
        boot.complete(message);
      }
    });

    final isolate = await Isolate.spawn<DesktopUsbIsolateConfig>(
      desktopUsbIsolateEntry,
      DesktopUsbIsolateConfig(device.portName, eventPort.sendPort),
      errorsAreFatal: false,
      debugName: 'flipper-usb-${device.portName}',
    );

    final result = await boot.future;
    await bootSub.cancel();

    if (result is DesktopUsbFault) {
      isolate.kill(priority: Isolate.immediate);
      eventPort.close();
      throw StateError(result.message);
    }
    final ready = result as DesktopUsbReady;
    return _DesktopUsbTransport._(isolate, eventPort, events, ready.commandPort);
  }

  @override
  bool get supportsCli => true;

  @override
  FlipperMode get initialMode => FlipperMode.cli;

  @override
  int get storageChunkSize => 1024;

  @override
  Future<void> open() async {
    _eventSub = _events.listen(_onIsolateMessage);
  }

  void _onIsolateMessage(dynamic message) {
    if (message is DesktopUsbBytes) {
      addBytes(message.bytes);
    } else if (message is DesktopUsbWriteAck) {
      final pending = _inFlight.remove(message.seq);
      if (pending == null || pending.isCompleted) return;
      if (message.error != null) {
        pending.completeError(StateError('Serial write failed: ${message.error}'));
      } else {
        pending.complete();
      }
    } else if (message is DesktopUsbFault) {
      LogService.log('[FlipperClient] desktop USB fault: ${message.message}');
      onTransportFault(StateError(message.message));
    } else if (message is DesktopUsbExited) {
      if (!_exited.isCompleted) _exited.complete();
      onTransportFault(StateError('USB isolate exited'));
    }
  }

  @override
  Future<void> rawWrite(Uint8List bytes) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    final seq = _writeSeq++;
    final completer = Completer<void>();
    _inFlight[seq] = completer;
    _commandPort.send(DesktopUsbWriteRequest(bytes, seq));
    return completer.future;
  }

  @override
  Future<void> nudgeCli() async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    _commandPort.send(const DesktopUsbDtrPulse());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await writeAscii('\r');
  }

  @override
  void onFaultExtra(Object error) {
    for (final pending in _inFlight.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _inFlight.clear();
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  Future<void> doClose() async {
    try {
      _commandPort.send(const DesktopUsbShutdown());
      await _exited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    } catch (_) {}
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _eventSub?.cancel();
    _eventSub = null;
    _eventPort.close();
    for (final pending in _inFlight.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Transport closed'));
      }
    }
    _inFlight.clear();
  }
}
