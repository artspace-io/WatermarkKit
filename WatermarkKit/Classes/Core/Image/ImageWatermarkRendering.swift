//
//  ImageWatermarkRendering.swift
//  WatermarkKit
//

import UIKit

/// 图片水印渲染协议。
///
/// 与视频协议拆开，图片实现不必被迫承担 `AVFoundation` 那套导出逻辑。
public protocol ImageWatermarkRendering: Sendable {
    func applyWatermark(to source: ImageSource, config: WatermarkConfig) async throws -> ImageWatermarkResult
}

public extension ImageWatermarkRendering {
    /// 直接处理 `UIImage` 的便利重载。
    ///
    /// 注意：`UIImage` 已经丢掉了原始 EXIF / GPS，这条路径下 `preservesMetadata` 无法生效，
    /// 结果中的 `metadataPreserved` 会是 `false`。需要保留拍摄信息请传 `.fileURL` 或 `.data`。
    func applyWatermark(to image: UIImage, config: WatermarkConfig) async throws -> ImageWatermarkResult {
        try await applyWatermark(to: .image(image), config: config)
    }
}
