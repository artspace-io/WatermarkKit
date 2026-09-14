//
//  WatermarkKit.swift
//  WatermarkKit
//

import AVFoundation
import UIKit

/// 门面入口，覆盖绝大多数调用场景。
///
/// 需要自定义渲染器或注入测试替身时，直接使用 `ImageWatermarkRenderer` /
/// `VideoWatermarkRenderer` / `WatermarkBatchProcessor`。
public enum WatermarkKit {

    public static let imageRenderer = ImageWatermarkRenderer()
    public static let videoRenderer = VideoWatermarkRenderer()

    /// 给图片加水印。
    public static func applyWatermark(
        to source: ImageSource,
        config: WatermarkConfig
    ) async throws -> ImageWatermarkResult {
        try await imageRenderer.applyWatermark(to: source, config: config)
    }

    /// 给视频加水印。
    public static func applyWatermark(
        to source: VideoSource,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil
    ) async throws -> VideoWatermarkResult {
        try await videoRenderer.applyWatermark(to: source, config: config, progress: progress)
    }

    /// 清理 Kit 产生的全部临时文件。
    ///
    /// 建议在 App 启动或处理队列清空后调用一次兜底。注意会一并删除
    /// 此前处理成功但调用方尚未搬走的文件。
    public static func cleanupTemporaryFiles() {
        TemporaryFileManager.shared.cleanupAll()
    }

    /// 临时目录当前占用的字节数。
    public static func temporaryFilesUsageBytes() -> Int64 {
        TemporaryFileManager.shared.currentUsageBytes()
    }

    /// 当前设备是否支持 HEIC 编码。不支持时输出会自动降级为 JPEG。
    public static var isHEICEncodingSupported: Bool {
        ImageEncoder.isHEICEncodingSupported
    }
}
