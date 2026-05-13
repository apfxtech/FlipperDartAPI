part of 'flipper_client.dart';

extension FlipperStorageApi on FlipperClient {
  Future<FlipperRpcBatch<ListResponse>> storageList(
    ListRequest request, {
    Duration timeout = const Duration(seconds: 8),
    FlipperRequestPriority priority = FlipperRequestPriority.foreground,
  }) {
    return callRpc(
      Main(storageListRequest: request),
      (frame) => frame.hasStorageListResponse() ? frame.storageListResponse : null,
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
      (frame) => frame.hasStorageReadResponse() ? frame.storageReadResponse : null,
      timeout: timeout,
      priority: priority,
    );
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
      (frame) => frame.hasStorageStatResponse() ? frame.storageStatResponse : null,
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
      (frame) => frame.hasStorageInfoResponse() ? frame.storageInfoResponse : null,
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

  static const int _kChunkSize = 512;

  Future<void> storageWriteChunked(
    String path,
    List<int> data, {
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(minutes: 10),
    FlipperRequestPriority priority = FlipperRequestPriority.background,
  }) async {
    final total = data.length;
    final totalFrames =
        total == 0 ? 1 : ((total + _kChunkSize - 1) ~/ _kChunkSize);
    LogService.log('[Storage] write "$path": ${total}B, $totalFrames frames');

    await callRpcFramesMulti(
      (sendFrame) async {
        var offset = 0;
        var frameIndex = 0;
        while (true) {
          final end =
              (offset + _kChunkSize) > total ? total : (offset + _kChunkSize);
          final chunk =
              offset == end ? const <int>[] : data.sublist(offset, end);
          final hasNext = end < total;

          final req = WriteRequest()
            ..path = path
            ..ensureFile().data = chunk;

          await sendFrame(Main(
            hasNext: hasNext,
            storageWriteRequest: req,
          ));

          offset = end;
          frameIndex++;
          if (total > 0) onProgress?.call(offset / total);
          if (!hasNext) break;
        }
        LogService.log('[Storage] $frameIndex frames sent, awaiting ACK');
      },
      timeout: timeout,
      priority: priority,
    );

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
