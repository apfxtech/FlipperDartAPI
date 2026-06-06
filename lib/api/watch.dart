part of '../flipper_client.dart';

extension FlipperWatchApi on FlipperClient {
  /// Battery stream with staggered update intervals.
  ///
  /// Emits partial [Map<String, String>] with `power.*` keys:
  /// - First emission (immediate): all power fields.
  /// - Every [currentInterval] (default 5 s): only `*current*` keys.
  /// - Every 3rd tick (~15 s): all power fields again.
  ///
  /// Stream ends when the client disconnects.
  Stream<Map<String, String>> watchBattery({
    Duration currentInterval = const Duration(seconds: 5),
  }) async* {
    if (!isConnected) return;

    // Initial full fetch — emit all fields immediately.
    try {
      final batch = await powerInfo(priority: FlipperRequestPriority.background);
      yield {for (final item in batch.items) 'power.${item.key}': item.value};
    } catch (e) {
      LogService.log('[watchBattery] initial fetch: $e');
      if (!isConnected) return;
    }

    var tick = 0;
    while (isConnected) {
      await Future<void>.delayed(currentInterval);
      if (!isConnected) break;
      tick++;

      try {
        final batch = await powerInfo(priority: FlipperRequestPriority.background);
        final all = {for (final item in batch.items) 'power.${item.key}': item.value};

        if (tick % 3 == 0) {
          // Full refresh every ~15 s.
          yield all;
        } else {
          // Emit only current-related keys every 5 s.
          final partial = Map.fromEntries(
            all.entries.where((e) => e.key.contains('current')),
          );
          if (partial.isNotEmpty) yield partial;
        }
      } catch (e) {
        LogService.log('[watchBattery] poll: $e');
        if (!isConnected) break;
      }
    }
  }

  /// Storage stream with staggered update intervals.
  ///
  /// Emits partial [Map<String, String>] with `storage.*` keys:
  /// - First emission (after [stagger]): `/ext` fields only (fast).
  /// - Second emission: combined `/ext` + `/int` (after storageDu completes).
  /// - Every [extInterval] (default 15 s): re-fetched `/ext` + cached `/int`.
  ///
  /// `/int` is fetched once and cached; it does not change at runtime.
  /// Stream ends when the client disconnects.
  Stream<Map<String, String>> watchStorage({
    Duration stagger = const Duration(seconds: 3),
    Duration extInterval = const Duration(seconds: 15),
  }) async* {
    if (!isConnected) return;

    // Small stagger so the battery request enters the queue first.
    await Future<void>.delayed(stagger);
    if (!isConnected) return;

    // Fetch /ext first — it is fast and unblocks the loading state.
    var extData = <String, String>{};
    try {
      final response = await storageInfo(
        InfoRequest(path: '/ext/'),
        priority: FlipperRequestPriority.background,
      );
      extData = _storageResponseToMap(response.single, 'storage.sdcard');
    } catch (e) {
      LogService.log('[watchStorage] /ext initial: $e');
      if (!isConnected) return;
    }

    if (extData.isNotEmpty) yield extData;

    // Fetch /int once in the same generator step — may take up to 30 s.
    var intData = <String, String>{};
    if (isConnected) {
      try {
        final bytes = await storageDu(
          '/int',
          priority: FlipperRequestPriority.background,
        );
        intData = {
          'storage.internal.used_bytes': '$bytes',
          'storage.internal.used': _watchFormatBytes(bytes),
        };
        yield {...extData, ...intData};
      } catch (e) {
        LogService.log('[watchStorage] /int du: $e');
      }
    }

    // Periodic /ext refresh; /int stays cached.
    while (isConnected) {
      await Future<void>.delayed(extInterval);
      if (!isConnected) break;

      try {
        final response = await storageInfo(
          InfoRequest(path: '/ext/'),
          priority: FlipperRequestPriority.background,
        );
        extData = _storageResponseToMap(response.single, 'storage.sdcard');
        yield {...extData, ...intData};
      } catch (e) {
        LogService.log('[watchStorage] /ext poll: $e');
        if (!isConnected) break;
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
