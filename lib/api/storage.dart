part of '../flipper_client.dart';

extension FlipperStorageApi on FlipperClient {
  Future<FlipperRpcBatch<ListResponse>> storageList(
    ListRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageListRequest: request),
      (frame) =>
          frame.hasStorageListResponse() ? frame.storageListResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }

  Future<FlipperRpcBatch<ReadResponse>> storageRead(
    ReadRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageReadRequest: request),
      (frame) =>
          frame.hasStorageReadResponse() ? frame.storageReadResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }

  /// Reads [path], reporting incremental progress as response frames arrive.
  /// When [expectedSize] is > 0 (e.g. the size from a prior directory listing),
  /// [onProgress] is called with a 0..1 ratio of bytes received; it always
  /// fires once with 1.0 on completion. Returns the assembled file bytes.
  Future<List<int>> storageReadChunked(
    String path, {
    int expectedSize = 0,
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(minutes: 5),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) async {
    var received = 0;
    final batch = await callRpc(
      Main(storageReadRequest: ReadRequest(path: path)),
      (frame) =>
          frame.hasStorageReadResponse() ? frame.storageReadResponse : null,
      timeout: timeout,
      priority: priority,
      onFrame: (frame) {
        if (!frame.hasStorageReadResponse()) return;
        final resp = frame.storageReadResponse;
        if (!resp.hasFile()) return;
        received += resp.file.data.length;
        if (expectedSize > 0) {
          onProgress?.call((received / expectedSize).clamp(0.0, 1.0));
        }
      },
    );
    final bytes = <int>[];
    for (final r in batch.items) {
      if (r.hasFile()) bytes.addAll(r.file.data);
    }
    onProgress?.call(1.0);
    return bytes;
  }

  Future<List<Main>> storageWrite(
    WriteRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.background,
  }) {
    return callRpcFrames(
      Main(storageWriteRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  Future<List<Main>> storageDelete(
    DeleteRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpcFrames(
      Main(storageDeleteRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  Future<List<Main>> storageMkdir(
    MkdirRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpcFrames(
      Main(storageMkdirRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  Future<FlipperRpcBatch<Md5sumResponse>> storageMd5sum(
    Md5sumRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageMd5sumRequest: request),
      (frame) =>
          frame.hasStorageMd5sumResponse() ? frame.storageMd5sumResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }

  Future<FlipperRpcBatch<StatResponse>> storageStat(
    StatRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageStatRequest: request),
      (frame) =>
          frame.hasStorageStatResponse() ? frame.storageStatResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }

  Future<FlipperRpcBatch<InfoResponse>> storageInfo(
    InfoRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageInfoRequest: request),
      (frame) =>
          frame.hasStorageInfoResponse() ? frame.storageInfoResponse : null,
      timeout: timeout,
      priority: priority,
    );
  }

  Future<List<Main>> storageRename(
    RenameRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpcFrames(
      Main(storageRenameRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  Future<List<Main>> storageBackupCreate(
    BackupCreateRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.background,
  }) {
    return callRpcFrames(
      Main(storageBackupCreateRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  Future<List<Main>> storageBackupRestore(
    BackupRestoreRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.background,
  }) {
    return callRpcFrames(
      Main(storageBackupRestoreRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }

  // On modern Flipper firmware, `/int` is aliased onto the SD card, so
  // `storageInfo("/int")` returns the SD card's total/free — not the actual
  // footprint of files in the internal namespace. Use this instead to get the
  // real used-bytes count via recursive directory walk.
  Future<int> storageDu(
    String path, {
    Duration timeout = const Duration(seconds: 30),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) async {
    var total = 0;
    final queue = <String>[path];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      FlipperRpcBatch<ListResponse> batch;
      try {
        batch = await storageList(
          ListRequest(path: dir),
          timeout: timeout,
          priority: priority,
        );
      } catch (e) {
        LogService.log('[StorageDu] list "$dir" failed: $e');
        continue;
      }
      for (final response in batch.items) {
        for (final entry in response.file) {
          if (entry.type == File_FileType.DIR) {
            final sub = dir.endsWith('/')
                ? '$dir${entry.name}'
                : '$dir/${entry.name}';
            queue.add(sub);
          } else {
            LogService.log(
              '[StorageDu] file "$dir/${entry.name}" size=${entry.size}',
            );
            total += entry.size;
          }
        }
      }
    }
    LogService.log('[StorageDu] "$path" total=$total');
    return total;
  }

  Future<FlipperRpcBatch<TimestampResponse>> storageTimestamp(
    TimestampRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageTimestampRequest: request),
      (frame) => frame.hasStorageTimestampResponse()
          ? frame.storageTimestampResponse
          : null,
      timeout: timeout,
      priority: priority,
    );
  }

  Future<void> storageWriteChunked(
    String path,
    List<int> data, {
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(seconds: 300),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) async {
    final total = data.length;
    final rpcChunkSize =
        _transport?.storageChunkSize ??
        _UniversalBleTransportBase._bleChunkSize;
    final totalFrames = total == 0
        ? 1
        : ((total + rpcChunkSize - 1) ~/ rpcChunkSize);
    LogService.log(
      '[Storage] write "$path": ${total}B, $totalFrames frames, '
      'rpcChunk=$rpcChunkSize',
    );

    Future<void> upload() {
      return callRpcFramesMulti(
        (sendFrame) async {
          var offset = 0;
          var frameIndex = 0;
          while (true) {
            final end = (offset + rpcChunkSize) > total
                ? total
                : (offset + rpcChunkSize);
            final chunk = offset == end
                ? const <int>[]
                : data.sublist(offset, end);
            final hasNext = end < total;

            final req = WriteRequest()
              ..path = path
              ..ensureFile().data = chunk;

            await sendFrame(Main(hasNext: hasNext, storageWriteRequest: req));

            offset = end;
            frameIndex++;
            if (total > 0) onProgress?.call(offset / total);
            if (!hasNext) break;
          }
          LogService.log('[Storage] $frameIndex frames sent, awaiting ACK');
        },
        timeout: timeout,
        priority: priority,
      ).then((_) {});
    }

    try {
      await upload();
    } catch (e) {
      if (!_isLinkDropError(e)) {
        LogService.log('[Storage] write "$path" failed: $e');
        rethrow;
      }
      // The link dropped mid-upload and the firmware lost the partial file.
      // If the automatic reconnect restores the session, restart the upload
      // exactly once — the firmware opens the file with CREATE_ALWAYS, so a
      // restart from offset 0 is safe.
      LogService.log('[Storage] write "$path" interrupted by link drop: $e');
      final restored = await _waitForRpcSession(const Duration(seconds: 30));
      if (!restored) {
        rethrow;
      }
      LogService.log('[Storage] link restored, restarting write "$path"');
      await upload();
    }

    onProgress?.call(1.0);
    LogService.log('[Storage] write "$path" complete');
  }

  Future<List<Main>> storageTarExtract(
    TarExtractRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.background,
  }) {
    return callRpcFrames(
      Main(storageTarExtractRequest: request),
      timeout: timeout,
      priority: priority,
    );
  }
}
