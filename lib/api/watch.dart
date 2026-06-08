part of '../flipper_client.dart';

extension FlipperWatchApi on FlipperClient {
  /// Broadcast stream of device-info patches.
  ///
  /// Each event is a partial [Map<String, String>] — subscribers merge it into
  /// their own state. Subscribing has no side-effects; call
  /// [startDeviceInfoCollection] to begin polling.
  Stream<Map<String, String>> get deviceInfoUpdates =>
      _deviceInfoWatchCtrl.stream;

  /// Start (or restart) the background collection cycle.
  ///
  /// Safe to call multiple times — each call cancels the previous cycle via
  /// the generation counter. Call from an external controller, not the library.
  void startDeviceInfoCollection() {
    final gen = ++_collectionGen;
    unawaited(_runCollection(gen));
  }

  /// Stop the running collection cycle.
  void stopDeviceInfoCollection() {
    _collectionGen++;
  }

  Future<void> _runCollection(int gen) async {
    if (!isConnected) return;

    void emit(Map<String, String> data) {
      if (gen != _collectionGen || _deviceInfoWatchCtrl.isClosed) return;
      _deviceInfoWatchCtrl.add(data);
    }

    bool alive() => gen == _collectionGen && isConnected;

    // ── Phase 1: initial burst ────────────────────────────────────────────

    final infoWasFetched = _deviceInfoFetched;

    // Device info is requested automatically on entering RPC mode. Individual
    // fields are emitted as they arrive; wait for the complete snapshot before
    // queueing lower-priority requests.
    try {
      await awaitDeviceInfo().timeout(const Duration(seconds: 20));
    } catch (e) {
      LogService.log('[watchInfo] device info: $e');
    }
    if (!alive()) return;

    // A completed request publishes its snapshot from _autoFetchDeviceInfo.
    // Re-emit only when collection starts after that broadcast was missed.
    if (infoWasFetched) {
      final cached = Map<String, String>.from(deviceInfoCache);
      if (cached.isNotEmpty) emit(cached);
    }
    if (!alive()) return;

    // Battery (full)
    try {
      final batch = await powerInfo(priority: FlipperRequestPriority.background);
      emit({for (final item in batch.items) 'power.${item.key}': item.value});
    } catch (e) {
      LogService.log('[watchInfo] battery initial: $e');
    }
    if (!alive()) return;

    // Protobuf version
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!alive()) return;
    try {
      final v = await protobufVersion(timeout: const Duration(seconds: 15));
      final major = v.single.major;
      final minor = v.single.minor;
      emit({
        'protobuf_version': '$major.$minor',
        'protobuf_version_major': '$major',
        'protobuf_version_minor': '$minor',
      });
    } catch (e) {
      LogService.log('[watchInfo] protobuf: $e');
    }
    if (!alive()) return;

    // DateTime
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!alive()) return;
    try {
      final response = await getDateTime(timeout: const Duration(seconds: 15));
      final dt = response.single.datetime;
      emit({
        'datetime': '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
            '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}',
      });
    } catch (e) {
      LogService.log('[watchInfo] datetime: $e');
    }
    if (!alive()) return;

    // Storage /ext — staggered so battery enters RPC queue first
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!alive()) return;
    var extData = <String, String>{};
    try {
      final response = await storageInfo(
        InfoRequest(path: '/ext/'),
        priority: FlipperRequestPriority.background,
      );
      extData = _storageResponseToMap(response.single, 'storage.sdcard');
      if (extData.isNotEmpty) emit(extData);
    } catch (e) {
      LogService.log('[watchInfo] storage /ext initial: $e');
    }
    if (!alive()) return;

    // Storage /int — slow (storageDu), fire-and-forget so periodic loop starts
    unawaited(() async {
      if (!alive()) return;
      try {
        final bytes = await storageDu(
          '/int',
          priority: FlipperRequestPriority.background,
        );
        if (alive()) {
          emit({
            'storage.internal.used_bytes': '$bytes',
            'storage.internal.used': _watchFormatBytes(bytes),
          });
        }
      } catch (e) {
        LogService.log('[watchInfo] storage /int: $e');
      }
    }());

    // ── Phase 2: periodic loop ────────────────────────────────────────────

    var tick = 0;
    const interval = Duration(seconds: 5);

    while (alive()) {
      await Future<void>.delayed(interval);
      if (!alive()) break;
      tick++;

      // Battery: partial every 5 s, full every 15 s
      try {
        final batch = await powerInfo(
          priority: FlipperRequestPriority.background,
        );
        final all = {
          for (final item in batch.items) 'power.${item.key}': item.value,
        };
        if (tick % 3 == 0) {
          emit(all);
        } else {
          final partial = Map.fromEntries(
            all.entries.where((e) => e.key.contains('current')),
          );
          if (partial.isNotEmpty) emit(partial);
        }
      } catch (e) {
        LogService.log('[watchInfo] battery poll: $e');
        if (!alive()) break;
      }

      // Storage /ext every 30 s, staggered 500 ms after battery
      if (alive() && tick % 6 == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!alive()) break;
        try {
          final response = await storageInfo(
            InfoRequest(path: '/ext/'),
            priority: FlipperRequestPriority.background,
          );
          extData = _storageResponseToMap(response.single, 'storage.sdcard');
          if (extData.isNotEmpty) emit(extData);
        } catch (e) {
          LogService.log('[watchInfo] storage /ext poll: $e');
          if (!alive()) break;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers (private to the flipperlib library).
// ---------------------------------------------------------------------------

Map<String, String> _storageResponseToMap(InfoResponse response, String prefix) {
  final total = response.totalSpace.toInt();
  final free = response.freeSpace.toInt();
  final used = total >= free ? total - free : 0;

  return {
    '$prefix.total': _watchFormatBytes(total),
    '$prefix.free': _watchFormatBytes(free),
    '$prefix.used': _watchFormatBytes(used),
    '$prefix.free_percent': _watchFormatPercent(free, total),
    '$prefix.used_percent': _watchFormatPercent(used, total),
    '$prefix.total_bytes': '$total',
    '$prefix.available_bytes': '$free',
    '$prefix.used_bytes': '$used',
  };
}

String _watchFormatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final precision = value >= 100 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _watchFormatPercent(int value, int total) {
  if (total <= 0) return '0%';
  return '${(value * 100 / total).toStringAsFixed(1)}%';
}

String _pad(int n) => n.toString().padLeft(2, '0');
