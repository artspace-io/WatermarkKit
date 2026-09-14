//
//  VideoWatermarkRenderer.swift
//  WatermarkKit
//

import AVFoundation
import Foundation

/// 视频水印渲染器。
///
/// 渲染策略为 `AVMutableVideoComposition` + Core Image：水印预先合成成一张叠加图，
/// 再逐帧混合到画面上。系统级合成、GPU 加速，长视频不会有内存爆炸风险。
/// 代价是无法逐帧改变水印内容 —— 属本期非目标。
public struct VideoWatermarkRenderer: VideoWatermarkRendering {

    private let exporter = VideoExporter()

    public init() {}

    public func applyWatermark(
        to source: VideoSource,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation?
    ) async throws -> VideoWatermarkResult {
        try Task.checkCancellation()
        guard !config.items.isEmpty else {
            throw WatermarkError.invalidConfiguration("未提供任何水印条目")
        }

        let asset = try source.resolveAsset()
        let plan = try await VideoCompositionBuilder.makePlan(
            asset: asset,
            config: config,
            sourceURL: source.fileURL
        )
        try Task.checkCancellation()

        let outputURL = try makeOutputURL(config: config)
        do {
            let output = try await exporter.export(
                plan: plan,
                config: config,
                outputURL: outputURL,
                progress: progress
            )
            return VideoWatermarkResult(
                fileURL: outputURL,
                renderSize: plan.renderSize,
                didDowngradeHDR: plan.isHDR && config.video.hdrPolicy == .downgradeToSDR,
                didSkipWatermark: plan.didSkipWatermark,
                appliedPreset: output.presetName,
                backgroundRestartCount: output.restartCount
            )
        } catch {
            // 失败或取消时不留半成品 —— 视频文件体积大，漏删会直接占用用户存储
            TemporaryFileManager.shared.discard(outputURL)
            throw error is WatermarkError ? error : WatermarkError.mapping(error)
        }
    }

    private func makeOutputURL(config: WatermarkConfig) throws -> URL {
        let fileExtension = config.video.fileType.preferredFileExtension

        switch config.output.destination {
        case .memoryOnly:
            throw WatermarkError.invalidConfiguration("视频不支持 memoryOnly，请使用 .temporary 或 .file(url)")

        case .temporary:
            return try TemporaryFileManager.shared.makeURL(fileExtension: fileExtension)

        case .file(let url):
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw WatermarkError.outputPathNotWritable(url, underlying: error)
            }
            // AVAssetExportSession 要求目标路径不存在，同名文件会直接导致导出失败
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw WatermarkError.outputPathNotWritable(url, underlying: error)
                }
            }
            return url
        }
    }
}

extension AVFileType {
    /// 导出文件的扩展名，未知类型退回 mp4。
    var preferredFileExtension: String {
        switch self {
        case .mp4:      return "mp4"
        case .mov:      return "mov"
        case .m4v:      return "m4v"
        default:        return "mp4"
        }
    }
}
