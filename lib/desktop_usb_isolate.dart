import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

class DesktopUsbIsolateConfig {
  final String portName;
  final SendPort eventPort;
  const DesktopUsbIsolateConfig(this.portName, this.eventPort);
}

class DesktopUsbWriteRequest {
  final Uint8List bytes;
  final int seq;
  const DesktopUsbWriteRequest(this.bytes, this.seq);
}

class DesktopUsbDtrPulse {
  const DesktopUsbDtrPulse();
}

class DesktopUsbShutdown {
  const DesktopUsbShutdown();
}

class DesktopUsbReady {
  final SendPort commandPort;
  const DesktopUsbReady(this.commandPort);
}

class DesktopUsbBytes {
  final Uint8List bytes;
  const DesktopUsbBytes(this.bytes);
}

class DesktopUsbWriteAck {
  final int seq;
  final String? error;
  const DesktopUsbWriteAck(this.seq, this.error);
}

class DesktopUsbFault {
  final String message;
  const DesktopUsbFault(this.message);
}

class DesktopUsbExited {
  const DesktopUsbExited();
}

void desktopUsbIsolateEntry(DesktopUsbIsolateConfig config) {
  final commandPort = ReceivePort();
  final SerialPort port;
  try {
    port = SerialPort(config.portName);
    if (!port.openReadWrite()) {
      config.eventPort.send(DesktopUsbFault('Failed to open ${config.portName}'));
      config.eventPort.send(const DesktopUsbExited());
      commandPort.close();
      return;
    }
    final cfg = SerialPortConfig()
      ..baudRate = 230400
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none;
    port.config = cfg;
  } catch (e) {
    config.eventPort.send(DesktopUsbFault('Open error: $e'));
    config.eventPort.send(const DesktopUsbExited());
    commandPort.close();
    return;
  }

  var shuttingDown = false;
  Timer? readTimer;

  void shutdown() {
    if (shuttingDown) return;
    shuttingDown = true;
    readTimer?.cancel();
    try {
      port.close();
    } catch (_) {}
    try {
      port.dispose();
    } catch (_) {}
    commandPort.close();
    config.eventPort.send(const DesktopUsbExited());
  }

  config.eventPort.send(DesktopUsbReady(commandPort.sendPort));

  commandPort.listen((message) {
    if (shuttingDown) return;
    if (message is DesktopUsbWriteRequest) {
      try {
        var offset = 0;
        while (offset < message.bytes.length) {
          final slice = offset == 0
              ? message.bytes
              : Uint8List.sublistView(message.bytes, offset);
          final n = port.write(slice, timeout: 5000);
          if (n <= 0) {
            config.eventPort.send(
              DesktopUsbWriteAck(message.seq, 'write returned $n at offset $offset'),
            );
            return;
          }
          offset += n;
        }
        config.eventPort.send(DesktopUsbWriteAck(message.seq, null));
      } catch (e) {
        config.eventPort.send(DesktopUsbWriteAck(message.seq, e.toString()));
      }
    } else if (message is DesktopUsbDtrPulse) {
      try {
        final c = port.config;
        c.dtr = 0;
        port.config = c;
        Future<void>.delayed(const Duration(milliseconds: 100), () {
          if (shuttingDown) return;
          try {
            final c2 = port.config;
            c2.dtr = 1;
            port.config = c2;
          } catch (_) {}
        });
      } catch (_) {}
    } else if (message is DesktopUsbShutdown) {
      shutdown();
    }
  });

  readTimer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    if (shuttingDown) return;
    try {
      final bytes = port.read(65536);
      if (bytes.isNotEmpty) {
        config.eventPort.send(DesktopUsbBytes(Uint8List.fromList(bytes)));
      }
    } catch (e) {
      if (!port.isOpen) {
        config.eventPort.send(DesktopUsbFault('Port closed: $e'));
        shutdown();
      }
    }
  });
}
