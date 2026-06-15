// Full-device recovery over DfuSe, run in a dedicated isolate. The DfuSe layer
// blocks (USB status polling with sleeps), so it must never touch the UI
// isolate. Mirrors qFlipper's FullRepairOperation
// (.sources/qflipper/backend/flipperzero/toplevel/fullrepairoperation.cpp) for
// the steps that are possible from the DFU bootloader: set recovery boot mode,
// flash the wireless (radio) stack, flash the firmware, correct the option
// bytes, then leave DFU. Post-boot asset/region provisioning is left to the
// normal RPC update flow once the device re-enumerates.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../log_service.dart';
import 'dfu_detector.dart';
import 'dfuse_file.dart';
import 'stm32wb55/option_bytes.dart';
import 'stm32wb55/stm32wb55.dart';

/// Recovery step identifiers reported to the UI.
enum RecoveryStep {
  settingBootMode,
  flashingRadio,
  flashingFirmware,
  correctingOptionBytes,
  restarting,
}

/// Inputs for a full repair, extracted from a Flipper `update.tgz` bundle
/// (`firmware.dfu`, `radio.bin`, and the `update.fuf` manifest's `Radio
/// address` / option-byte fields). All file contents are passed by value so the
/// isolate is self-contained. The radio is optional; complete option-byte data
/// is required because recovery mode must be restored to normal boot at the end.
class RecoveryRequest {
  RecoveryRequest({
    required this.firmwareDfu,
    required this.obReference,
    required this.obCompareMask,
    required this.obWriteMask,
    this.radioBin,
    this.radioAddress,
  });

  final Uint8List firmwareDfu;
  final Uint8List? radioBin;
  final int? radioAddress;
  final Uint8List obReference; // 128 bytes
  final Uint8List obCompareMask; // 128 bytes
  final Uint8List obWriteMask; // 128 bytes
}

/// Applies the update manifest's option-byte correction rule.
///
/// The compare mask decides whether the current value is acceptable, while the
/// write mask limits which bits recovery is allowed to modify.
Uint8List correctedOptionBytes({
  required Uint8List current,
  required Uint8List reference,
  required Uint8List writeMask,
}) {
  _requireOptionBytesSize('current option bytes', current);
  _requireOptionBytesSize('OB reference', reference);
  _requireOptionBytesSize('OB write mask', writeMask);

  final corrected = Uint8List(OptionBytes.sizeBytes);
  for (var i = 0; i < OptionBytes.sizeBytes; i++) {
    corrected[i] =
        (current[i] & (~writeMask[i] & 0xFF)) | (reference[i] & writeMask[i]);
  }
  return corrected;
}

bool optionBytesMatch({
  required Uint8List current,
  required Uint8List reference,
  required Uint8List compareMask,
}) {
  _requireOptionBytesSize('current option bytes', current);
  _requireOptionBytesSize('OB reference', reference);
  _requireOptionBytesSize('OB compare mask', compareMask);

  for (var i = 0; i < OptionBytes.sizeBytes; i++) {
    if ((current[i] & compareMask[i]) != reference[i]) return false;
  }
  return true;
}

void _requireOptionBytesSize(String name, Uint8List data) {
  if (data.length != OptionBytes.sizeBytes) {
    throw ArgumentError(
      '$name must be ${OptionBytes.sizeBytes} bytes, got ${data.length}',
    );
  }
}

// ── Isolate → main messages ──────────────────────────────────────────────────

sealed class RecoveryMessage {
  const RecoveryMessage();
}

class RecoveryProgress extends RecoveryMessage {
  const RecoveryProgress(this.step, this.percent);
  final RecoveryStep step;
  final double percent; // 0..100
}

class RecoveryLog extends RecoveryMessage {
  const RecoveryLog(this.message);
  final String message;
}

class RecoveryDone extends RecoveryMessage {
  const RecoveryDone();
}

class RecoveryFailed extends RecoveryMessage {
  const RecoveryFailed(this.error);
  final String error;
}

class _RecoveryConfig {
  _RecoveryConfig(this.sendPort, this.request);
  final SendPort sendPort;
  final RecoveryRequest request;
}

/// Spawns the recovery isolate and surfaces its progress as a stream. The
/// stream completes after [RecoveryDone] or [RecoveryFailed].
Stream<RecoveryMessage> runRecovery(RecoveryRequest request) {
  final controller = StreamController<RecoveryMessage>();
  final receivePort = ReceivePort();
  Isolate? isolate;

  void finish(RecoveryMessage message) {
    if (controller.isClosed) return;
    controller.add(message);
    receivePort.close();
    unawaited(controller.close());
  }

  receivePort.listen((dynamic message) {
    if (message is RecoveryMessage) {
      if (message is RecoveryDone || message is RecoveryFailed) {
        finish(message);
      } else if (!controller.isClosed) {
        controller.add(message);
      }
    }
  });

  unawaited(
    Isolate.spawn(
      _recoveryIsolateEntry,
      _RecoveryConfig(receivePort.sendPort, request),
      errorsAreFatal: true,
      debugName: 'flipper-dfu-recovery',
    ).then<void>((spawned) => isolate = spawned).catchError((Object e) {
      finish(RecoveryFailed('Failed to start recovery: $e'));
    }),
  );

  controller.onCancel = () {
    isolate?.kill(priority: Isolate.immediate);
    receivePort.close();
  };
  return controller.stream;
}

void _recoveryIsolateEntry(_RecoveryConfig cfg) {
  final send = cfg.sendPort.send;
  try {
    _runRecovery(cfg.request, send);
    send(const RecoveryDone());
  } catch (e, st) {
    LogService.log('[Recovery] failed: $e\n$st');
    send(RecoveryFailed(e.toString()));
  }
}

void _runRecovery(RecoveryRequest req, void Function(Object) send) {
  if (!DfuUsb.instance.available) {
    throw StateError('Raw USB (libusb) is not available on this platform');
  }

  _validateOptionBytesRequest(req);
  send(
    RecoveryLog(
      'Starting recovery: firmware=${req.firmwareDfu.length}B, '
      'radio=${req.radioBin?.length ?? 0}B',
    ),
  );

  // 1. Force recovery boot mode before touching flash. Writing option bytes
  //    resets and re-enumerates the device; the next transaction waits for it.
  send(const RecoveryProgress(RecoveryStep.settingBootMode, 0));
  _withDevice('set recovery boot mode', (dev) {
    final optionBytes = dev.optionBytes();
    if (!optionBytes.isValid) {
      throw StateError('Failed to read option bytes before recovery');
    }
    send(
      RecoveryLog(
        'Boot mode before recovery: '
        'nBOOT0=${optionBytes.value('nBOOT0')}, '
        'nSWBOOT0=${optionBytes.value('nSWBOOT0')}',
      ),
    );
    optionBytes.setValue('nBOOT0', 0);
    optionBytes.setValue('nSWBOOT0', 0);
    send(const RecoveryLog('Setting recovery boot mode and resetting device'));
    if (!dev.setOptionBytes(optionBytes)) {
      throw StateError('Failed to set recovery boot mode');
    }
  });
  send(const RecoveryLog('Waiting for DFU device to re-enumerate'));
  _waitForDfuReenumeration();
  send(const RecoveryProgress(RecoveryStep.settingBootMode, 100));

  // 2. Flash the wireless (radio) stack to the manifest's address, if provided.
  //    Non-fatal — qFlipper proceeds to the firmware even if this fails (the
  //    radio usually survives a firmware brick).
  final radioBin = req.radioBin;
  final radioAddress = req.radioAddress;
  if (radioBin != null && radioBin.isNotEmpty && radioAddress != null) {
    try {
      _withDevice('flash radio', (dev) {
        dev.onProgress = (op, pct) =>
            send(RecoveryProgress(RecoveryStep.flashingRadio, pct));
        send(
          RecoveryLog(
            'Radio target address 0x${radioAddress.toRadixString(16)}',
          ),
        );
        if (!dev.erase(radioAddress, radioBin.length)) {
          throw StateError('Failed to erase radio region');
        }
        if (!dev.download(radioBin, radioAddress, 0)) {
          throw StateError('Failed to flash radio stack');
        }
      });
    } catch (e) {
      send(RecoveryLog('Radio flash failed ($e); continuing with firmware'));
    }
  }
  send(const RecoveryProgress(RecoveryStep.flashingRadio, 100));

  // 3. Flash the firmware (.dfu container).
  send(const RecoveryProgress(RecoveryStep.flashingFirmware, 0));
  final fw = DfuseFile.parse(req.firmwareDfu);
  if (!fw.isValid) throw StateError('Firmware .dfu file is not valid');
  final totalElements = fw.images.fold<int>(
    0,
    (n, img) => n + img.elements.length,
  );
  send(
    RecoveryLog(
      'Firmware: ${req.firmwareDfu.length}B, ${fw.images.length} image(s), '
      '$totalElements element(s)',
    ),
  );
  if (totalElements == 0) {
    throw StateError('Firmware .dfu has no image elements to flash');
  }
  _withDevice('flash firmware', (dev) {
    dev.onProgress = (op, pct) =>
        send(RecoveryProgress(RecoveryStep.flashingFirmware, pct));
    if (!dev.downloadFile(fw)) throw StateError('Failed to flash firmware');
  });
  send(const RecoveryProgress(RecoveryStep.flashingFirmware, 100));

  // 4. Correct option bytes and return to normal boot. Compare and write masks
  //    have distinct meanings and must not be interchanged.
  send(const RecoveryProgress(RecoveryStep.correctingOptionBytes, 0));
  final reference = req.obReference;
  final compareMask = req.obCompareMask;
  final writeMask = req.obWriteMask;
  _withDevice('correct option bytes', (dev) {
    final current = dev.readOptionBytesRaw();
    if (current.length != OptionBytes.sizeBytes) {
      throw StateError('Failed to read option bytes after flashing');
    }
    if (optionBytesMatch(
      current: current,
      reference: reference,
      compareMask: compareMask,
    )) {
      send(const RecoveryLog('Option bytes already match; leaving DFU'));
      if (!dev.leave()) throw StateError('Failed to leave DFU mode');
      return;
    }

    final corrected = correctedOptionBytes(
      current: current,
      reference: reference,
      writeMask: writeMask,
    );
    if (!optionBytesMatch(
      current: corrected,
      reference: reference,
      compareMask: compareMask,
    )) {
      throw StateError(
        'Option bytes contain mismatches outside the writable mask',
      );
    }

    var changedBytes = 0;
    for (var i = 0; i < OptionBytes.sizeBytes; i++) {
      if (corrected[i] != current[i]) changedBytes++;
    }
    if (changedBytes > 0) {
      send(RecoveryLog('Correcting option bytes ($changedBytes byte(s))'));
      if (!dev.writeOptionBytesRaw(corrected)) {
        throw StateError('Failed to write corrected option bytes');
      }
    } else {
      throw StateError('Option bytes mismatch but no writable bits can fix it');
    }
  });
  send(const RecoveryProgress(RecoveryStep.correctingOptionBytes, 100));
  send(const RecoveryProgress(RecoveryStep.restarting, 100));
}

void _validateOptionBytesRequest(RecoveryRequest req) {
  _requireOptionBytesSize('OB reference', req.obReference);
  _requireOptionBytesSize('OB compare mask', req.obCompareMask);
  _requireOptionBytesSize('OB write mask', req.obWriteMask);

  for (var i = 0; i < OptionBytes.sizeBytes; i++) {
    if ((req.obReference[i] & (~req.obCompareMask[i] & 0xFF)) != 0) {
      throw StateError('OB reference has bits outside compare mask at byte $i');
    }
    if ((req.obWriteMask[i] & (~req.obCompareMask[i] & 0xFF)) != 0) {
      throw StateError('OB write mask exceeds compare mask at byte $i');
    }
  }
}

// Acquires a DFU device, runs [body] inside an open transaction, and always
// releases the device reference. Retries acquisition because the device
// re-enumerates after the resets earlier steps trigger.
void _withDevice(String what, void Function(Stm32Wb55 dev) body) {
  LogService.log('[Recovery] acquiring device for: $what');
  final address = _acquireDevice();
  final dev = Stm32Wb55(address);
  try {
    if (!dev.beginTransaction()) {
      throw StateError('$what: failed to open DFU device');
    }
    LogService.log('[Recovery] transaction started: $what');
    try {
      body(dev);
    } finally {
      dev.endTransaction();
      LogService.log('[Recovery] transaction ended: $what');
    }
  } finally {
    DfuUsb.instance.releaseDevice(address);
  }
}

int _acquireDevice({Duration timeout = const Duration(seconds: 15)}) {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final address = DfuUsb.instance.acquireDevice();
    if (address != null) return address;
    sleep(const Duration(milliseconds: 250));
  }
  throw StateError('DFU device not found within ${timeout.inSeconds}s');
}

void _waitForDfuReenumeration({
  Duration timeout = const Duration(seconds: 15),
  Duration settleDelay = const Duration(milliseconds: 750),
}) {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (DfuUsb.instance.isPresent()) {
      sleep(settleDelay);
      if (DfuUsb.instance.isPresent() && _canOpenDfuDevice()) return;
    }
    sleep(const Duration(milliseconds: 100));
  }
  throw StateError(
    'DFU device did not become ready within ${timeout.inSeconds}s',
  );
}

bool _canOpenDfuDevice() {
  final address = DfuUsb.instance.acquireDevice();
  if (address == null) return false;
  final dev = Stm32Wb55(address);
  try {
    if (!dev.beginTransaction()) return false;
    dev.endTransaction();
    return true;
  } catch (_) {
    return false;
  } finally {
    DfuUsb.instance.releaseDevice(address);
  }
}
