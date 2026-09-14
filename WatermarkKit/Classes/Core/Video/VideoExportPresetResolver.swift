//
//  VideoExportPresetResolver.swift
//  WatermarkKit
//

import AVFoundation
import CoreGraphics

/// 导出预设选择。
///
/// `AVAssetExportSession` 只接受预设，没有任何设置码率的 API，因此这里做的是
/// **档位选择**而非码率控制 —— 所谓「避免文件膨胀」是通过挑一个更低的预设间接实现的近似效果，
/// 不能承诺「输出码率不超过源码率」。精确码率控制需要改走 `AVAssetWriter`。
enum VideoExportPresetResolver {

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
            level = level.oneStepLower
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
            if isCompatible { compatible.append(presetName) }
        }
        return compatible.isEmpty ? candidates : compatible
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
    /// 该档位的候选预设，按质量降序，前面的不被支持时退到后面。
    ///
    /// 最高档一路兜到 medium：HEVC 在模拟器与部分老设备上没有编码器，
    /// 而 `AVAssetExportPresetHighestQuality` 遇到超大尺寸素材也可能失败，
    /// 宁可画质降一档也好过整个导出失败。实际生效的预设由 `appliedPreset` 回传。
    var presetChain: [String] {
        switch self {
        case .highest:
            return [
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHighestQuality,
                AVAssetExportPresetMediumQuality
            ]
        case .medium:
            return [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
        case .low:
            return [AVAssetExportPresetLowQuality, AVAssetExportPresetMediumQuality]
        }
    }

    var oneStepLower: VideoQualityPreset {
        switch self {
        case .highest:  return .medium
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
