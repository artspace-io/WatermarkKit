//
//  OutputConfig.swift
//  WatermarkKit
//

import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// 图片输出格式。
public enum WatermarkImageFormat: Sendable, Equatable {
    case jpeg(quality: CGFloat)
    case png
    /// HEIC 在 A9 及更早设备、部分模拟器上无硬件编码支持，此时自动降级为等质量 JPEG，
    /// 降级结果通过 `ImageWatermarkResult.actualFormat` 与 `didFallbackFromHEIC` 回传。
    case heic(quality: CGFloat)

    var utType: CFString {
        switch self {
        case .jpeg:  return UTType.jpeg.identifier as CFString
        case .png:   return UTType.png.identifier as CFString
        case .heic:  return UTType.heic.identifier as CFString
        }
    }

    var compressionQuality: CGFloat? {
        switch self {
        case .jpeg(let quality), .heic(let quality): return min(max(quality, 0), 1)
        case .png: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .heic: return "heic"
        }
    }
}

/// 输出去向。
public enum WatermarkDestination: Sendable, Equatable {
    /// 只返回内存中的 `UIImage`，不落盘。视频不支持该选项。
    case memoryOnly
    /// 写入指定路径，调用方自行管理生命周期。
    case file(URL)
    /// 写入 Kit 管理的临时目录，失败或取消时自动清理，成功后所有权移交调用方。
    case temporary
}

/// 图片 / 视频共用的导出配置。
public struct OutputConfig: Sendable, Equatable {
    public var imageFormat: WatermarkImageFormat
    /// 保留 EXIF / TIFF / 拍摄时间等元数据。
    ///
    /// 仅当输入能提供原始编码数据（`ImageSource.fileURL` / `.data`）时才可能生效；
    /// 输入为 `UIImage` 时原始元数据已经丢失，结果中的 `metadataPreserved` 会标记为 `false`。
    public var preservesMetadata: Bool
    /// 单独控制 GPS 定位信息，默认剥离。
    ///
    /// 仅在 `preservesMetadata == true` 时有意义。加水印后的图片通常用于分享，
    /// 默认不把用户的位置一起发出去。
    public var preservesLocation: Bool
    public var destination: WatermarkDestination

    public init(
        imageFormat: WatermarkImageFormat = .jpeg(quality: 0.92),
        preservesMetadata: Bool = true,
        preservesLocation: Bool = false,
        destination: WatermarkDestination = .memoryOnly
    ) {
        self.imageFormat = imageFormat
        self.preservesMetadata = preservesMetadata
        self.preservesLocation = preservesLocation
        self.destination = destination
    }

    public static let `default` = OutputConfig()
}

/// 视频导出质量档位。
///
/// 不提供 `.custom(bitrate:)` —— `AVAssetExportSession` 没有任何设置码率的 API，
/// 精确码率控制必须改走 `AVAssetWriter`，属后续版本范围。
public enum VideoQualityPreset: Sendable, Equatable {
    case highest
    case medium
    case low
}

/// HDR 素材处理策略。
public enum HDRPolicy: Sendable, Equatable {
    /// 正常加水印，画面降级为 SDR，结果中标记 `didDowngradeHDR`。
    case downgradeToSDR
    /// 跳过水印，原样转存以保住画质。
    case skipWatermark
}

/// App 切入后台时的导出策略。
public enum BackgroundPolicy: Sendable, Equatable {
    /// 切后台时中止当前导出并申请后台任务，回到前台后自动重新发起。
    ///
    /// 注意：`AVAssetExportSession` 不支持真正的暂停续跑，「续跑」实为「重跑」。
    /// 长视频场景下用户会看到进度条退回起点，这是当前渲染方案的固有限制。
    case suspendAndResume
    /// 切后台即以 `.interrupted` 失败，不做重试。
    case failFast
}

/// 视频专有导出配置。
public struct VideoOutputConfig: Sendable, Equatable {
    public var qualityPreset: VideoQualityPreset
    public var fileType: AVFileType
    public var preservesAudio: Bool
    public var hdrPolicy: HDRPolicy
    public var backgroundPolicy: BackgroundPolicy
    /// 源码率明显低于目标预设时自动降档，避免低码率素材导出后文件反而变大。
    ///
    /// 这是近似控制而非精确上限 —— `AVAssetExportSession` 无法指定码率，
    /// 只能通过选择更低的预设间接影响输出。
    public var avoidsFileSizeInflation: Bool

    public init(
        qualityPreset: VideoQualityPreset = .highest,
        fileType: AVFileType = .mp4,
        preservesAudio: Bool = true,
        hdrPolicy: HDRPolicy = .downgradeToSDR,
        backgroundPolicy: BackgroundPolicy = .suspendAndResume,
        avoidsFileSizeInflation: Bool = true
    ) {
        self.qualityPreset = qualityPreset
        self.fileType = fileType
        self.preservesAudio = preservesAudio
        self.hdrPolicy = hdrPolicy
        self.backgroundPolicy = backgroundPolicy
        self.avoidsFileSizeInflation = avoidsFileSizeInflation
    }

    public static let `default` = VideoOutputConfig()
}
