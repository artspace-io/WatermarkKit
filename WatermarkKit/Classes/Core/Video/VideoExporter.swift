//
//  VideoExporter.swift
//  WatermarkKit
//

import AVFoundation
import OSLog
import UIKit

/// 视频导出执行器。
///
/// ⚠️ 本文件集中使用 `AVAssetExportSession` 的同步属性与 `exportAsynchronously`。
/// 这套 API 自 iOS 18 起标记为弃用，但最低支持版本是 iOS 16，新 API 尚不可用，
/// 因此新 SDK 下编译会出现弃用告警。待最低版本提升到 18 后，只需替换本文件即可完成迁移。
final class VideoExporter: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.watermarkkit",
        category: "VideoExport"
    )

    struct Output {
        let presetName: String
        let restartCount: Int
    }

    /// 后台中断后的重新导出次数上限，避免用户反复切换时无限重跑。
    private static let maxBackgroundRestarts = 3
    private static let progressPollInterval: UInt64 = 100_000_000   // 100ms

    func export(
        plan: VideoCompositionBuilder.Plan,
        config: WatermarkConfig,
        outputURL: URL,
        progress: AsyncStream<Double>.Continuation?
    ) async throws -> Output {
        let candidates = await resolveCandidates(plan: plan, config: config)
        guard !candidates.isEmpty else {
            throw WatermarkError.unsupportedFormat(
                "没有可用的导出预设与 \(config.video.fileType.rawValue) 匹配"
            )
        }
        var presetIndex = 0
        var restartCount = 0

        while true {
            try Task.checkCancellation()
            let presetName = candidates[presetIndex]
            do {
                try await runAttempt(
                    plan: plan,
                    config: config,
                    presetName: presetName,
                    outputURL: outputURL,
                    progress: progress
                )
                try await verifyOutputSize(
                    for: outputURL,
                    expectedSize: plan.renderSize,
                    presetName: presetName
                )
                return Output(presetName: presetName, restartCount: restartCount)
            } catch WatermarkError.interrupted {
                guard config.video.backgroundPolicy == .suspendAndResume,
                      restartCount < Self.maxBackgroundRestarts else {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw WatermarkError.interrupted
                }
                restartCount += 1
                // AVAssetExportSession 无法续写，只能删掉半成品从头再来 —— 用户会看到进度回退
                try? FileManager.default.removeItem(at: outputURL)
                progress?.yield(0)
                await BackgroundExportGuard.waitForForeground()
            } catch WatermarkError.cancelled {
                try? FileManager.default.removeItem(at: outputURL)
                throw WatermarkError.cancelled
            } catch {
                // 编码器缺失这类失败要跑到真正建立编码会话时才暴露，事前的兼容性查询挡不住，
                // 所以失败一次就降到下一个候选预设再试，全部试完才算真失败。
                Self.logger.error("预设 \(presetName) 导出失败: \(error.localizedDescription)，尝试下一个候选")
                try? FileManager.default.removeItem(at: outputURL)
                presetIndex += 1
                guard presetIndex < candidates.count else { throw error }
                progress?.yield(0)
            }
        }
    }

    /// 事前挑掉当前设备跑不通的预设，至少保留一个供导出阶段兜底。
    private func resolveCandidates(
        plan: VideoCompositionBuilder.Plan,
        config: WatermarkConfig
    ) async -> [String] {
        let candidates = VideoExportPresetResolver.candidates(
            for: config.video.qualityPreset,
            renderSize: plan.renderSize,
            frameRate: plan.frameRate,
            sourceDataRate: plan.sourceDataRate,
            avoidsFileSizeInflation: config.video.avoidsFileSizeInflation
        )
        let compatible = await VideoExportPresetResolver.compatiblePresets(
            among: candidates,
            asset: plan.composition,
            fileType: config.video.fileType
        )
        Self.logger.info(
            "导出候选预设: \(candidates), renderSize: \(Int(plan.renderSize.width))×\(Int(plan.renderSize.height)), 兼容结果: \(compatible)"
        )
        return compatible
    }

    // MARK: - 单次导出

    private func runAttempt(
        plan: VideoCompositionBuilder.Plan,
        config: WatermarkConfig,
        presetName: String,
        outputURL: URL,
        progress: AsyncStream<Double>.Continuation?
    ) async throws {
        let session = try await makeSession(
            plan: plan,
            config: config,
            presetName: presetName,
            outputURL: outputURL
        )
        try await checkDiskSpace(session: session, outputURL: outputURL)

        let box = ExportSessionBox(session)
        let state = ExportRunState()
        let guardian = await BackgroundExportGuard(
            session: box,
            state: state,
            policy: config.video.backgroundPolicy
        )
        let monitor = startProgressMonitor(session: box, progress: progress)

        defer {
            monitor.cancel()
            Task { @MainActor in guardian.invalidate() }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        // 后台守护的取消与用户主动取消走同一个回调，靠状态位区分
                        continuation.resume(
                            throwing: state.wasInterruptedByBackground
                                ? WatermarkError.interrupted
                                : WatermarkError.cancelled
                        )
                    default:
                        continuation.resume(throwing: WatermarkError.mapping(session.error))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }

        progress?.yield(1)
    }

    // MARK: - Session 组装

    private func makeSession(
        plan: VideoCompositionBuilder.Plan,
        config: WatermarkConfig,
        presetName: String,
        outputURL: URL
    ) async throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: plan.composition, presetName: presetName),
              session.supportedFileTypes.contains(config.video.fileType) else {
            throw WatermarkError.unsupportedFormat(
                "设备不支持导出预设 \(presetName) 与 \(config.video.fileType.rawValue) 的组合"
            )
        }

        // AVAssetExportSession 拒绝已存在的目标路径；降级重试时上一轮的半成品必须先清掉
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = config.video.fileType
        session.videoComposition = try await plan.makeVideoComposition()
        session.shouldOptimizeForNetworkUse = true
        return session
    }

    /// 导出前的磁盘空间粗筛。
    ///
    /// 只是提示性检查 —— 真实的空间不足由 `AVError.diskFull` 事后映射，
    /// 事前判断存在 TOCTOU 问题，不作为准确性保证。
    /// 估算拿不到就直接跳过，粗筛失败不该挡住导出。
    private func checkDiskSpace(session: AVAssetExportSession, outputURL: URL) async throws {
        guard let estimated = try? await session.estimatedOutputFileLengthInBytes, estimated > 0 else { return }

        let directory = outputURL.deletingLastPathComponent()
        guard let available = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return }

        // 留 20% 余量，编码过程中的临时占用通常高于最终文件大小
        if available < Int64(Double(estimated) * 1.2) {
            throw WatermarkError.diskFull
        }
    }

    /// 导出后校验输出视频尺寸是否符合预期，拦截「预设偷缩分辨率」等静默异常。
    ///
    /// `AVAssetExportSession` 的 `MediumQuality` / `LowQuality` 等预设会把输出
    /// 分辨率压到更小（竖屏 1320×2868 实测被压到 220×480），
    /// 而 `HighestQuality` 系列严格等于 `renderSize`。此校验在导出成功后比对，
    /// 不符时记录错误日志，供排查预设行为。
    private func verifyOutputSize(
        for outputURL: URL,
        expectedSize: CGSize,
        presetName: String
    ) async {
        let asset = AVURLAsset(url: outputURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            Self.logger.warning("无法读取输出文件视频轨道以校验尺寸: \(outputURL.path)")
            return
        }
        do {
            let naturalSize = try await track.load(.naturalSize)
            let matches = abs(naturalSize.width - expectedSize.width) < 2
                && abs(naturalSize.height - expectedSize.height) < 2
            if matches {
                Self.logger.info(
                    "输出尺寸校验通过: \(Int(naturalSize.width))×\(Int(naturalSize.height))（预设 \(presetName)）"
                )
            } else {
                Self.logger.error(
                    "输出尺寸与预期不符: 实际 \(Int(naturalSize.width))×\(Int(naturalSize.height))，\" + \"预期 \(Int(expectedSize.width))×\(Int(expectedSize.height))（预设 \(presetName)）"
                )
            }
        } catch {
            Self.logger.warning("读取输出轨道尺寸失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 进度

    private func startProgressMonitor(
        session: ExportSessionBox,
        progress: AsyncStream<Double>.Continuation?
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.progressPollInterval)
                guard !Task.isCancelled else { return }
                progress?.yield(Double(session.progress))
            }
        }
    }
}
