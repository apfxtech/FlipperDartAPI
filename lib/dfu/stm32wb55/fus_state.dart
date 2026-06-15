// STM32WB55 FUS (Firmware Upgrade Service) state — Dart port of qFlipper's
// FUSState (.sources/qflipper/dfu/device/stm32wb55/fusstate.{h,cpp}). Read from
// the FUS status register; drives wireless-stack repair decisions.

enum FusStatus { idle, fwUpgradeOngoing, fusUpgradeOngoing, serviceOngoing, errorOccured, invalid }

enum FusError {
  noError,
  imageNotFound,
  imageCorrupt,
  imageNotAuthentic,
  notEnoughSpace,
  userAbort,
  eraseError,
  writeError,
  stTagNotFound,
  customTagNotFound,
  authKeyLocked,
  rollBackError,
  notRunning,
  unknown,
}

class FusState {
  FusState(int statusByte, int errorByte)
    : status = _normalizeStatus(statusByte),
      error = _decodeError(errorByte);

  const FusState._(this.status, this.error);

  static const FusState invalid =
      FusState._(FusStatus.invalid, FusError.unknown);

  final FusStatus status;
  final FusError error;

  bool get isValid => status != FusStatus.invalid;

  // Some statuses come back as a range (0x1n/0x2n/0x3n); normalise to the base
  // value before mapping (matches `m_status & 0xFFFFFFF0`).
  static FusStatus _normalizeStatus(int raw) {
    switch (raw) {
      case 0x00:
        return FusStatus.idle;
      case 0xFF:
        return FusStatus.errorOccured;
    }
    switch (raw & 0xF0) {
      case 0x10:
        return FusStatus.fwUpgradeOngoing;
      case 0x20:
        return FusStatus.fusUpgradeOngoing;
      case 0x30:
        return FusStatus.serviceOngoing;
      default:
        return FusStatus.invalid;
    }
  }

  static FusError _decodeError(int raw) {
    switch (raw) {
      case 0x00:
        return FusError.noError;
      case 0x01:
        return FusError.imageNotFound;
      case 0x02:
        return FusError.imageCorrupt;
      case 0x03:
        return FusError.imageNotAuthentic;
      case 0x04:
        return FusError.notEnoughSpace;
      case 0x05:
        return FusError.userAbort;
      case 0x06:
        return FusError.eraseError;
      case 0x07:
        return FusError.writeError;
      case 0x08:
        return FusError.stTagNotFound;
      case 0x09:
        return FusError.customTagNotFound;
      case 0x0A:
        return FusError.authKeyLocked;
      case 0x11:
        return FusError.rollBackError;
      case 0xFE:
        return FusError.notRunning;
      default:
        return FusError.unknown;
    }
  }

  @override
  String toString() => 'FusState(${status.name}, ${error.name})';
}
