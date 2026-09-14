//
//  PhotosWatermarking.swift
//  WatermarkKit/Photos
//

import AVFoundation
import Photos

/// 直接以 `PHAsset` 为输入的便利入口。
public extension VideoWatermarkRendering {

    /// 处理相册视频，自动完成 iCloud 下载。
    ///
    /// 进度做了分段映射：下载占 0 ~ 0.3，导出占 0.3 ~ 1。
    /// iCloud 上的大视频下载耗时可能超过导出本身，不单独计入进度会让进度条长时间停在 0。
    func applyWatermark(
        to phAsset: PHAsset,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil
    ) async throws -> VideoWatermarkResult {
        let downloadShare = 0.3

        let source = try await PhotosAdapter.videoSource(from: phAsset) { value in
            progress?.yield(value * downloadShare)
        }
        try Task.checkCancellation()

        var exportContinuation: AsyncStream<Double>.Continuation?
        let exportStream = AsyncStream<Double> { exportContinuation = $0 }
        let relay = Task {
            for await value in exportStream {
                progress?.yield(downloadShare + value * (1 - downloadShare))
            }
        }
        defer {
            exportContinuation?.finish()
            relay.cancel()
        }

        return try await applyWatermark(to: source, config: config, progress: exportContinuation)
    }
}

public extension ImageWatermarkRendering {

    /// 处理相册图片，自动完成 iCloud 下载。
    ///
    /// 走的是原始编码数据，因此 `preservesMetadata` 在这条路径上能真正生效。
    func applyWatermark(
        to phAsset: PHAsset,
        config: WatermarkConfig,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ImageWatermarkResult {
        let source = try await PhotosAdapter.imageSource(from: phAsset, downloadProgress: downloadProgress)
        try Task.checkCancellation()
        return try await applyWatermark(to: source, config: config)
    }
}
