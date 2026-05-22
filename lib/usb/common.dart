part of '../flipper_client.dart';

abstract class _UsbPlatform {
  Future<List<FlipperDevice>> loadDevices();

  bool includeDevice(FlipperDevice device);

  Future<_Transport> openTransport(UsbDiscoveredDevice device);
}

abstract class _SerialUsbPlatformBase implements _UsbPlatform {
  const _SerialUsbPlatformBase();

  String metadataDescription(SerialPort port) =>
      _readSerialString(() => port.description) ?? '';

  int? metadataVendorId(SerialPort port) => _readSerialInt(() => port.vendorId);

  int? metadataProductId(SerialPort port) =>
      _readSerialInt(() => port.productId);

  String? metadataSerialNumber(SerialPort port) =>
      _readSerialString(() => port.serialNumber);

  FlipperDevice serialDevice(
    String portName, {
    required String description,
    required int? vendorId,
    required int? productId,
    required String? serialNumber,
  }) {
    return FlipperDevice(
      id: portName,
      name: description.isNotEmpty ? description : portName,
      link: FlipperLink.usb,
      source: DesktopUsbDiscoveredDevice(
        portName,
        description,
        vendorId: vendorId,
        productId: productId,
        serialNumber: serialNumber,
      ),
      vendorId: vendorId,
      productId: productId,
      serialNumber: serialNumber,
    );
  }

  T? _readSerialProperty<T>(T? Function() read) {
    try {
      return read();
    } catch (e) {
      LogService.log('[USB] failed to read serial port metadata: $e');
      return null;
    }
  }

  int? _readSerialInt(int? Function() read) => _readSerialProperty(read);

  String? _readSerialString(String? Function() read) =>
      _readSerialProperty(read);
}

abstract class _SerialUsbTransportBase extends _Transport {
  final Isolate _isolate;
  final ReceivePort _eventPort;
  final Stream<dynamic> _events;
  final SendPort _commandPort;
  final Map<int, Completer<void>> _inFlight = {};
  final Completer<void> _exited = Completer<void>();
  StreamSubscription<dynamic>? _eventSub;
  int _writeSeq = 0;

  _SerialUsbTransportBase(
    this._isolate,
    this._eventPort,
    this._events,
    this._commandPort,
  );

  static Future<T> createFor<T extends _SerialUsbTransportBase>(
    DesktopUsbDiscoveredDevice device,
    T Function(
      Isolate isolate,
      ReceivePort eventPort,
      Stream<dynamic> events,
      SendPort commandPort,
    )
    build,
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

    final result = await boot.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          const DesktopUsbFault('Timed out opening USB serial port'),
    );
    await bootSub.cancel();

    if (result is DesktopUsbFault) {
      isolate.kill(priority: Isolate.immediate);
      eventPort.close();
      throw StateError(result.message);
    }
    final ready = result as DesktopUsbReady;
    return build(isolate, eventPort, events, ready.commandPort);
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
        pending.completeError(
          StateError('Serial write failed: ${message.error}'),
        );
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
