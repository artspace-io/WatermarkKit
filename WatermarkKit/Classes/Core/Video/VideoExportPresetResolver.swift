//
//  VideoExportPresetResolver.swift
//  WatermarkKit
//

import AVFoundation
import CoreGraphics
import OSLog

/// 导出预设选择。
///
/// `AVAssetExportSession` 只接受预设，没有任何设置码率的 API，因此这里做的是
/// **档位选择**而非码率控制。各档位在「分辨率」上的行为差异巨大，必须先说清楚：
///
/// - `.highest`（`AVAssetExportPresetHEVCHighestQuality` / `AVAssetExportPresetHighestQuality`）：
///   输出严格等于 `videoComposition.renderSize`，即原视频分辨率（偶数对齐后）。
/// - `.medium` / `.low`（`AVAssetExportPresetMediumQuality` / `LowQuality`）：
///   质量与尺寸全交给系统决定，**实际输出分辨率可能被压缩**。已实测：竖屏 1320×2868 走
///   `MediumQuality` 被压到 220×480、720×1280 被压到 320×568。
///
/// 因此追求「导出原分辨率」只能依赖 `.highest`，必要时宁可导出失败也不该偷偷降档
/// 到会缩分辨率的预设。精确码率控制仍需改走 `AVAssetWriter`。
enum VideoExportPresetResolver {

    private static let logger = Logger(
        subsystem: "com.watermarkkit",
        category: "VideoExportPreset"
    )

    /// 按优先级返回候选预设名，调用方依次尝试直到找到设备支持的那个。
    ///
    /// 优先 HEVC 预设：`AVAssetExportPresetHighestQuality` 会对低分辨率素材升采样，
    /// 导致文件变大而画质没有提升。
    static func candidates(
        for quality: VideoQualityPreset,
        renderSize: CGSize,
        frameRate: Float,
        sourceDataRate: Float,
        avoidsFileSizeInflation: Bool
    ) -> [String] {
        var level = quality
        if avoidsFileSizeInflation,
           shouldDowngrade(
               from: quality,
               renderSize: renderSize,
               frameRate: frameRate,
               sourceDataRate: sourceDataRate
           ) {
            let downgraded = level.oneStepLower
            if downgraded != level {
                logger.info("源码率明显低于目标档位，按防膨胀从 \(quality) 降档到 \(downgraded)")
            }
            level = downgraded
        }
        return level.presetChain
    }

    /// 过滤掉当前设备 / 素材组合下不可用的预设。
    ///
    /// 这一步是必需的：`AVAssetExportSession(asset:presetName:)` 对不受支持的预设
    /// 照样返回非 nil 的会话，`supportedFileTypes` 也照样列出 mp4 —— 真正的失败要等到
    /// 编码器创建时才暴露（日志里的 `VT-CS signalled err=-129xx`）。最典型的是模拟器：
    /// 没有 HEVC 编码器，`AVAssetExportPresetHEVC*` 一律跑不通。
    ///
    /// 过滤结果为空时退回未过滤的候选 —— 兼容性查询本身也可能误判，
    /// 与其直接报错，不如交给导出阶段的逐个降级重试去兜。
    static func compatiblePresets(
        among candidates: [String],
        asset: AVAsset,
        fileType: AVFileType
    ) async -> [String] {
        var compatible: [String] = []
        for presetName in candidates {
            let isCompatible = await AVAssetExportSession.compatibility(
                ofExportPreset: presetName,
                with: asset,
                outputFileType: fileType
            )
            logger.info("预设 \(presetName) 与素材/\(fileType.rawValue) 兼容: \(isCompatible)")
            if isCompatible { compatible.append(presetName) }
        }
        let result = compatible.isEmpty ? candidates : compatible
        if compatible.isEmpty {
            logger.error("无预设通过兼容性检测，退回未过滤候选 \(candidates)")
        }
        return result
    }

    /// 源码率明显低于目标档位的典型输出时降一档。
    ///
    /// 这里用「像素 × 帧率 × 每像素比特数」估算目标档位的典型码率 —— 是经验值而非系统实际行为，
    /// 只用来识别「源素材本来就很省码率」这种明显情况，不追求精确。
    private static func shouldDowngrade(
        from quality: VideoQualityPreset,
        renderSize: CGSize,
        frameRate: Float,
        sourceDataRate: Float
    ) -> Bool {
        guard sourceDataRate > 0, renderSize.width > 0, renderSize.height > 0 else { return false }
        let pixels = Double(renderSize.width * renderSize.height)
        let fps = Double(frameRate > 0 ? frameRate : 30)
        let estimated = pixels * fps * quality.bitsPerPixel
        // 留 40% 余量，避免正常素材被误降档
        return Double(sourceDataRate) < estimated * 0.6
    }
}

private extension VideoQualityPreset {
    /// 该档位的候选预设，按质量降序，前面的不被支持时退到后面。实际生效的预设由 `appliedPreset` 回传。
    ///
    /// `.highest` 只保留 HEVC / H.264 最高档，不再兜到 Medium：`MediumQuality` / `LowQuality`
    /// 会被系统压缩输出分辨率，悄悄缩图比导出失败更隐蔽。编码器在两个最高档都不可用
    /// （模拟器无 HEVC、个别设备/极端素材）时，由导出阶段报显式错误，而不是降档换缩小的结果。
    var presetChain: [String] {
        switch self {
        case .highest:
            return [
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHighestQuality
            ]
        case .medium:
            return [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
        case .low:
            return [AVAssetExportPresetLowQuality, AVAssetExportPresetMediumQuality]
        }
    }

    /// 防膨胀自动降一档。
    ///
    /// `.highest` 不降档：降档到 `.medium` 意味着把输出分辨率交给系统缩放，
    /// 「保分辨率」与「防膨胀」冲突时保分辨率优先 —— 用户选了 `.highest` 就是要原尺寸，
    /// 不该为了文件大小偷偷缩小画面。要压缩尺寸请显式改用 `.medium` / `.low`。
    var oneStepLower: VideoQualityPreset {
        switch self {
        case .highest:  return .highest
        case .medium:   return .low
        case .low:      return .low
        }
    }

    /// 该档位的经验每像素比特数，用于估算典型输出码率。
    var bitsPerPixel: Double {
        switch self {
        case .highest:  return 0.12
        case .medium:   return 0.06
        case .low:      return 0.025
        }
    }
}
