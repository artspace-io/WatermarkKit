//
//  VideoWatermarkRendering.swift
//  WatermarkKit
//

import AVFoundation
import Foundation

/// 视频水印渲染协议。
public protocol VideoWatermarkRendering: Sendable {
    /// 进度以 `AsyncStream.Continuation` 暴露，而不是逃逸闭包 ——
    /// 后者在 Swift 6 严格并发下会触发 `Sendable` 告警，且回调线程不明确。
    func applyWatermark(
        to source: VideoSource,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation?
    ) async throws -> VideoWatermarkResult
}

public extension VideoWatermarkRendering {

    func applyWatermark(to source: VideoSource, config: WatermarkConfig) async throws -> VideoWatermarkResult {
        try await applyWatermark(to: source, config: config, progress: nil)
    }

    /// 返回结果与进度流的便利重载。
    ///
    /// ```swift
    /// let (stream, task) = renderer.watermarkWithProgress(url, config: config)
    /// Task { for await value in stream { updateUI(value) } }
    /// let result = try await task.value
    /// ```
    func watermarkWithProgress(
        _ source: VideoSource,
        config: WatermarkConfig
    ) -> (progress: AsyncStream<Double>, task: Task<VideoWatermarkResult, Error>) {
        var continuation: AsyncStream<Double>.Continuation?
        let stream = AsyncStream<Double> { continuation = $0 }
        let captured = continuation

        let task = Task {
            defer { captured?.finish() }
            return try await applyWatermark(to: source, config: config, progress: captured)
        }
        return (stream, task)
    }
}
