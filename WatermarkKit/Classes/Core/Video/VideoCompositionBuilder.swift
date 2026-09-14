//
//  VideoCompositionBuilder.swift
//  WatermarkKit
//

import AVFoundation
import CoreImage
import UIKit

/// 把源素材与水印图层组装成可导出的合成描述。
///
/// 渲染走 Core Image：水印先预合成成一张整画布大小的叠加图，再由
/// `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` 逐帧混合到画面上。
///
/// 早期版本用的是 `AVVideoCompositionCoreAnimationTool` + CALayer 图层树，已弃用，原因有三：
/// 1. 它内部靠 `CARenderer` 离屏渲染，在 iOS 模拟器上绑定 IOSurface 会直接 trap
///    （`_xpc_api_misuse`），整个视频管线在模拟器上不可用。
/// 2. Core Animation 进后台会整个挂起，表现为导出进度卡住且不报错，得额外做停滞检测兜底。
/// 3. 图层树是一次性的，不能跨 `AVAssetExportSession` 复用，重试路径上要小心翼翼地重建。
/// Core Image 这三条都没有。
enum VideoCompositionBuilder {

    struct Plan {
        let composition: AVComposition
        /// 已应用 `preferredTransform` 后的尺寸，即用户看到的方向与大小。
        let renderSize: CGSize
        let frameRate: Float
        let sourceDataRate: Float
        let isHDR: Bool
        let didSkipWatermark: Bool

        /// 预合成好的水印叠加图，整段视频只算这一次。
        fileprivate let overlayGroups: [WatermarkCompositor.OverlayGroup]

        /// 为一次导出尝试生成合成描述。跳过水印时返回 nil，让导出走接近转存的轻量路径。
        func makeVideoComposition() async throws -> AVVideoComposition? {
            guard !didSkipWatermark else { return nil }
            return try await VideoCompositionBuilder.makeVideoComposition(plan: self)
        }
    }

    static func makePlan(
        asset: AVAsset,
        config: WatermarkConfig,
        sourceURL: URL?
    ) async throws -> Plan {
        guard try await asset.load(.isReadable) else {
            throw WatermarkError.assetNotReadable(sourceURL)
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw WatermarkError.noVideoTrack(sourceURL)
        }

        async let naturalSizeTask = videoTrack.load(.naturalSize)
        async let transformTask = videoTrack.load(.preferredTransform)
        async let frameRateTask = videoTrack.load(.nominalFrameRate)
        async let dataRateTask = videoTrack.load(.estimatedDataRate)
        async let durationTask = asset.load(.duration)

        let (naturalSize, preferredTransform, nominalFrameRate, estimatedDataRate, duration) =
            try await (naturalSizeTask, transformTask, frameRateTask, dataRateTask, durationTask)

        let renderSize = renderSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw WatermarkError.unsupportedFormat("视频尺寸非法：\(naturalSize)")
        }

        let isHDR = await detectHDR(videoTrack)
        let skipsWatermark = isHDR && config.video.hdrPolicy == .skipWatermark

        let composition = try await makeComposition(
            asset: asset,
            videoTrack: videoTrack,
            duration: duration,
            preferredTransform: preferredTransform,
            preservesAudio: config.video.preservesAudio
        )

        // 跳过水印时不解析布局，导出会走接近转存的轻量路径，最大限度保住画质
        let overlayGroups: [WatermarkCompositor.OverlayGroup]
        if skipsWatermark {
            overlayGroups = []
        } else {
            let placements = try LayoutResolver.resolve(config: config, canvasSize: renderSize)
            overlayGroups = WatermarkCompositor.makeOverlayGroups(placements, canvasSize: renderSize)
        }

        return Plan(
            composition: composition,
            renderSize: renderSize,
            frameRate: nominalFrameRate,
            sourceDataRate: estimatedDataRate,
            isHDR: isHDR,
            didSkipWatermark: skipsWatermark,
            overlayGroups: overlayGroups
        )
    }

    // MARK: - 尺寸

    /// 应用 `preferredTransform` 之后的画面尺寸，即用户看到的方向与大小。
    ///
    /// 这里只算尺寸、不算变换：方向由 `applyingCIFiltersWithHandler` 负责，
    /// 它读的是合成轨道上的 `preferredTransform`，交付给 handler 的 `sourceImage` 已经摆正。
    /// 我们只需要知道画布多大，才能把水印布局到正确的位置。
    static func renderSize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(
            width: aligned(abs(transformed.width)),
            height: aligned(abs(transformed.height))
        )
    }

    /// 向下对齐到偶数。
    ///
    /// H.264 / HEVC 的色度子采样要求宽高均为偶数，奇数的 `renderSize` 会让编码会话
    /// 建不起来（控制台表现为 `VT-CS signalled err=-129xx`，导出直接失败）。
    /// 裁掉的这 1 像素肉眼不可见，比整个导出失败划算。
    /// 小于 2 的一律判为 0，交给外层的尺寸合法性检查去报错。
    private static func aligned(_ value: CGFloat) -> CGFloat {
        let rounded = value.rounded()
        guard rounded >= 2 else { return 0 }
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
    }

    // MARK: - 轨道

    private static func makeComposition(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime,
        preferredTransform: CGAffineTransform,
        preservesAudio: Bool
    ) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)

        guard let videoSlot = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw WatermarkError.exportFailed(underlying: nil)
        }
        do {
            try videoSlot.insertTimeRange(range, of: videoTrack, at: .zero)
        } catch {
            throw WatermarkError.mapping(error)
        }
        // 方向的唯一来源：跳过水印时靠它保住方向，走 videoComposition 时
        // `applyingCIFiltersWithHandler` 也是读它来摆正 sourceImage 的
        videoSlot.preferredTransform = preferredTransform

        if preservesAudio, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            if let audioSlot = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                // 音轨缺失不应导致整个处理失败，静默降级为无声输出
                try? audioSlot.insertTimeRange(range, of: audioTrack, at: .zero)
            }
        }
        return composition
    }

    // MARK: - 合成与水印叠加

    private static func makeVideoComposition(plan: Plan) async throws -> AVVideoComposition {
        let groups = plan.overlayGroups
        let renderSize = plan.renderSize

        let videoComposition: AVMutableVideoComposition
        do {
            videoComposition = try await AVMutableVideoComposition.videoComposition(
                with: plan.composition,
                applyingCIFiltersWithHandler: { request in
                    request.finish(
                        with: compose(groups, over: request.sourceImage, renderSize: renderSize),
                        context: nil
                    )
                }
            )
        } catch {
            throw WatermarkError.mapping(error)
        }

        // 帧率不覆盖：不设 frameDuration 时 AVFoundation 跟随源轨道的原始时序，
        // 比我们把 29.97 这类取整成 30 更准确
        videoComposition.renderSize = renderSize
        return videoComposition
    }

    /// 把各组叠加图依次混合到画面上。
    ///
    /// `sourceImage` 已经摆正，其 extent 可能比对齐后的 `renderSize` 大 1 像素，
    /// 所以最后要裁一次 —— 叠加图正是按 `renderSize` 画的，两者必须对齐。
    private static func compose(
        _ groups: [WatermarkCompositor.OverlayGroup],
        over sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage {
        let origin = sourceImage.extent.origin
        var output = sourceImage

        for group in groups {
            let overlay = CIImage(cgImage: group.image)
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            output = overlay.applyingFilter(
                group.blendMode.coreImageFilterName,
                parameters: [kCIInputBackgroundImageKey: output]
            )
        }
        return output.cropped(to: CGRect(origin: origin, size: renderSize))
    }

    // MARK: - HDR 检测

    private static func detectHDR(_ track: AVAssetTrack) async -> Bool {
        if let characteristics = try? await track.load(.mediaCharacteristics),
           characteristics.contains(.containsHDRVideo) {
            return true
        }
        // 部分素材没有声明 characteristic，再按传输函数兜底判断一次
        guard let descriptions = try? await track.load(.formatDescriptions) else { return false }
        let hdrTransferFunctions: Set<String> = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        ]
        return descriptions.contains { description in
            let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any]
            let transferFunction = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String
            return transferFunction.map(hdrTransferFunctions.contains) ?? false
        }
    }
}
