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
  /// the generation counter. The cycle binds to the session that is active at
  /// start time and dies as soon as that session stops being the active one
  /// (an activation swap restarts collection for the new device).
  /// Call from an external controller, not the library.
  void startDeviceInfoCollection() {
    final gen = ++_collectionGen;
    final session = _active;
    if (session == null) return;
    unawaited(_runCollection(gen, session));
  }

  /// Stop the running collection cycle.
  void stopDeviceInfoCollection() {
    _collectionGen++;
  }

  void freezeWatch() => _watchFreezeCount++;

  void unfreezeWatch() {
    if (_watchFreezeCount > 0) _watchFreezeCount--;
  }

  Future<void> _runCollection(int gen, _FlipperSession session) async {
    if (!session.isConnected) return;

    void emit(Map<String, String> data) {
      if (gen != _collectionGen) return;
      session._publishDeviceInfoPatch(data);
    }

    // Every RPC below goes through the facade, which routes to the active
    // session. alive() is always checked synchronously right before a call,
    // so a request can never land on another session: an activation swap
    // kills the loop at the next check.
    bool alive() =>
        gen == _collectionGen &&
        session.isConnected &&
        identical(_active, session);

    // Phase 1: initial burst

    final infoWasFetched = session._deviceInfoFetched;

    // Device info is requested automatically on entering RPC mode. Individual
    // fields are emitted as they arrive; wait for the complete snapshot before
    // queueing lower-priority requests.
    try {
      await session.awaitDeviceInfo().timeout(const Duration(seconds: 20));
    } catch (e) {
      LogService.log('[watchInfo] device info: $e');
    }
    if (!alive()) return;

    // A completed request publishes its snapshot from _fetchDeviceInfoOnce.
    // Re-emit only when collection starts after that broadcast was missed.
    if (infoWasFetched) {
      final cached = Map<String, String>.from(session.deviceInfoCache);
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

    // Storage /ext — staggered so battery enters RPC queue first. This is the
    // only unconditional storage-info fetch; afterwards it refreshes purely
    // reactively (see phase 2).
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!alive()) return;
    Future<void> fetchExtInfo(String stage) async {
      try {
        final response = await storageInfo(
          InfoRequest(path: '/ext/'),
          priority: FlipperRequestPriority.background,
        );
        final extData = _storageResponseToMap(response.single, 'storage.sdcard');
        if (extData.isNotEmpty) emit(extData);
      } catch (e) {
        LogService.log('[watchInfo] storage /ext $stage: $e');
      }
    }

    await fetchExtInfo('initial');
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

    // Phase 2: periodic battery poll + reactive storage refresh.
    //
    // Storage info is never polled on a timer after the phase-1 snapshot: it
    // refreshes only in response to completed mutating storage operations
    // (client.storageMutations), debounced and rate-limited:
    //  - the refresh runs 1 s after the last completion, so a burst of
    //    operations (e.g. write + delete + rename of a safe replace)
    //    produces exactly one refresh;
    //  - refreshes are at least 5 s apart;
    //  - nothing is sent while another storage RPC is in flight — the timer
    //    just re-checks later instead of queueing behind a long transfer.
    const storageQuietDelay = Duration(seconds: 1);
    const storageMinInterval = Duration(seconds: 5);
    // (Stopwatch, not DateTime: the protobuf bindings shadow dart:core
    // DateTime inside this library.)
    final clock = Stopwatch()..start();
    Duration? lastRefreshAt;
    Timer? refreshTimer;

    void scheduleStorageRefresh() {
      if (!alive()) return;
      var delay = storageQuietDelay;
      final last = lastRefreshAt;
      if (last != null) {
        final untilAllowed = last + storageMinInterval - clock.elapsed;
        if (untilAllowed > delay) delay = untilAllowed;
      }
      refreshTimer?.cancel();
      refreshTimer = Timer(delay, () {
        if (!alive()) return;
        if (_watchFreezeCount > 0 ||
            session.storageBusy ||
            session._mode != FlipperMode.rpc ||
            session.cliExclusive) {
          // The link is occupied; check again after another quiet window.
          scheduleStorageRefresh();
          return;
        }
        lastRefreshAt = clock.elapsed;
        unawaited(fetchExtInfo('refresh'));
      });
    }

    final mutationSub = session._storageMutationCtrl.stream.listen(
      (_) => scheduleStorageRefresh(),
    );

    var tick = 0;
    const interval = Duration(seconds: 5);
    const fullEvery = 12;

    try {
      while (alive()) {
        await Future<void>.delayed(interval);
        if (!alive()) break;
        if (_watchFreezeCount > 0) continue;
        // A CLI session owns the transport: polling would only throw
        // "RPC switch blocked" every tick and spam the log. Skip quietly and
        // resume once the client is back in RPC mode.
        if (session._mode != FlipperMode.rpc || session.cliExclusive) continue;
        // Frozen while storage operations run: a battery poll queued behind
        // a long transfer would only time out and spam errors.
        if (session.storageBusy) continue;
        tick++;

        if (tick % fullEvery == 0) {
          try {
            final batch = await powerInfo(
              priority: FlipperRequestPriority.background,
            );
            emit({
              for (final item in batch.items) 'power.${item.key}': item.value,
            });
          } catch (e) {
            LogService.log('[watchInfo] battery full: $e');
            if (!alive()) break;
          }
        } else {
          try {
            final batch = await propertyGet(
              GetRequest(key: 'pwrinfo.battery.current'),
              priority: FlipperRequestPriority.background,
            );
            final partial = {
              for (final item in batch.items)
                'power.${item.key.replaceAll('.', '_')}': item.value,
            };
            if (partial.isNotEmpty) emit(partial);
          } catch (e) {
            LogService.log('[watchInfo] battery current: $e');
            if (!alive()) break;
          }
        }
      }
    } finally {
      refreshTimer?.cancel();
      await mutationSub.cancel();
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
