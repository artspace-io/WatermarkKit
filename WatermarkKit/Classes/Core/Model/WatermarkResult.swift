//
//  WatermarkResult.swift
//  WatermarkKit
//

import CoreGraphics
import UIKit

/// 图片处理结果。
///
/// 返回结构体而非裸 `UIImage`，是为了把「实际发生了什么」如实回传 ——
/// HEIC 是否降级、元数据是否真的保住了，业务方需要据此决定是否提示用户。
public struct ImageWatermarkResult: @unchecked Sendable {
    public let image: UIImage
    /// 落盘路径，`destination == .memoryOnly` 时为 `nil`。
    public let fileURL: URL?
    /// 实际使用的编码格式，可能与请求的不同（HEIC 降级）。
    public let actualFormat: WatermarkImageFormat
    /// 是否因设备不支持 HEIC 编码而降级为 JPEG。
    public let didFallbackFromHEIC: Bool
    /// 元数据是否真的保留下来了。
    ///
    /// 请求了 `preservesMetadata` 但输入是 `UIImage`（原始元数据已丢失）时为 `false`。
    public let metadataPreserved: Bool

    init(
        image: UIImage,
        fileURL: URL? = nil,
        actualFormat: WatermarkImageFormat,
        didFallbackFromHEIC: Bool = false,
        metadataPreserved: Bool = false
    ) {
        self.image = image
        self.fileURL = fileURL
        self.actualFormat = actualFormat
        self.didFallbackFromHEIC = didFallbackFromHEIC
        self.metadataPreserved = metadataPreserved
    }
}

/// 视频处理结果。
public struct VideoWatermarkResult: Sendable {
    public let fileURL: URL
    /// 最终渲染尺寸（已应用 `preferredTransform`，即用户看到的方向）。
    public let renderSize: CGSize
    /// 源素材是 HDR 且已按策略降级为 SDR。
    public let didDowngradeHDR: Bool
    /// 因 `hdrPolicy == .skipWatermark` 而未叠加水印。
    public let didSkipWatermark: Bool
    /// 实际使用的 `AVAssetExportSession` 预设名。
    public let appliedPreset: String
    /// 因切入后台而重新发起过导出的次数。
    ///
    /// 大于 0 说明用户经历了进度回退 —— `AVAssetExportSession` 无法真正续跑，
    /// 这个字段用于评估当前方案在长视频上的体验代价。
    public let backgroundRestartCount: Int

    init(
        fileURL: URL,
        renderSize: CGSize,
        didDowngradeHDR: Bool = false,
        didSkipWatermark: Bool = false,
        appliedPreset: String,
        backgroundRestartCount: Int = 0
    ) {
        self.fileURL = fileURL
        self.renderSize = renderSize
        self.didDowngradeHDR = didDowngradeHDR
        self.didSkipWatermark = didSkipWatermark
        self.appliedPreset = appliedPreset
        self.backgroundRestartCount = backgroundRestartCount
    }
}
