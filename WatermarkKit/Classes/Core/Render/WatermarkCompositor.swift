//
//  WatermarkCompositor.swift
//  WatermarkKit
//

import UIKit

/// 水印实例的绘制与预合成。
///
/// 图片管线把水印直接画在底图上；视频管线先把水印拍平成一张透明叠加图，
/// 再由 Core Image 逐帧叠到画面上。两条管线共用下面这段绘制代码，
/// 同一份配置在两种介质上的输出因此是逐像素一致的。
enum WatermarkCompositor {

    /// 一组可以一次性叠加的水印。
    ///
    /// 组内实例的混合模式相同，预先拍平成一张整画布大小的图；组与组之间保持原有前后次序。
    /// `CGImage` 不可变，跨并发域传递是安全的。
    struct OverlayGroup: @unchecked Sendable {
        let image: CGImage
        /// 整组与画面混合时使用的模式。
        let blendMode: CGBlendMode
    }

    /// 把水印实例逐个画进上下文。
    ///
    /// - Parameter blendMode: 传 nil 表示各自使用 `placement.blendMode`（图片管线，
    ///   水印直接与底图混合）；传具体值表示统一覆盖 —— 预合成叠加图时传 `.normal`，
    ///   与画面的混合留到 Core Image 阶段再做。
    static func draw(
        _ placements: [ResolvedPlacement],
        into cgContext: CGContext,
        blendMode: CGBlendMode? = nil
    ) {
        cgContext.interpolationQuality = .high

        for placement in placements {
            cgContext.saveGState()
            cgContext.setAlpha(placement.opacity)
            cgContext.setBlendMode(blendMode ?? placement.blendMode)
            cgContext.translateBy(x: placement.center.x, y: placement.center.y)
            if placement.rotation != 0 {
                cgContext.rotate(by: placement.rotation)
            }
            // CGImage 的原点在左下，直接画进 UIKit 上下文会上下颠倒，先翻转 y 轴
            cgContext.scaleBy(x: 1, y: -1)
            let rect = CGRect(
                x: -placement.size.width / 2,
                y: -placement.size.height / 2,
                width: placement.size.width,
                height: placement.size.height
            )
            cgContext.draw(placement.raster.image, in: rect)
            cgContext.restoreGState()
        }
    }

    /// 把水印实例按混合模式切成若干组，每组预合成为一张整画布大小的透明叠加图。
    ///
    /// 水印是静态的（逐帧变化本就是非目标），所以整段视频只需要合成这一次，
    /// 之后每帧只是一次图像混合。
    ///
    /// 分组按**相邻**实例切分而不是字典归类 —— zIndex 决定的前后次序必须保住。
    /// 绝大多数配置只有一组（全部 `.normal`），逐帧阶段就只有一次混合。
    static func makeOverlayGroups(
        _ placements: [ResolvedPlacement],
        canvasSize: CGSize
    ) -> [OverlayGroup] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }

        return consecutiveRuns(of: placements).compactMap { run in
            guard let first = run.first, let image = flatten(run, canvasSize: canvasSize) else { return nil }
            return OverlayGroup(image: image, blendMode: first.blendMode)
        }
    }

    // MARK: - 内部

    /// 按相邻实例的混合模式切段。
    private static func consecutiveRuns(of placements: [ResolvedPlacement]) -> [[ResolvedPlacement]] {
        var runs: [[ResolvedPlacement]] = []
        for placement in placements {
            if let last = runs.last, last[0].blendMode == placement.blendMode {
                runs[runs.count - 1].append(placement)
            } else {
                runs.append([placement])
            }
        }
        return runs
    }

    private static func flatten(_ placements: [ResolvedPlacement], canvasSize: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1            // 画布已是像素尺寸，再乘屏幕倍率会导致二次放大
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            // 组内实例之间正常叠放，整组与画面的混合交给 Core Image
            draw(placements, into: context.cgContext, blendMode: .normal)
        }
        return image.cgImage
    }
}

extension CGBlendMode {
    /// 对应的 Core Image 混合滤镜名，映射不到的一律退回 source-over（正常叠加）。
    ///
    /// 这些滤镜都以 `inputImage` 为前景、`kCIInputBackgroundImageKey` 为背景。
    var coreImageFilterName: String {
        switch self {
        case .multiply:     return "CIMultiplyBlendMode"
        case .screen:       return "CIScreenBlendMode"
        case .overlay:      return "CIOverlayBlendMode"
        case .darken:       return "CIDarkenBlendMode"
        case .lighten:      return "CILightenBlendMode"
        case .colorDodge:   return "CIColorDodgeBlendMode"
        case .colorBurn:    return "CIColorBurnBlendMode"
        case .softLight:    return "CISoftLightBlendMode"
        case .hardLight:    return "CIHardLightBlendMode"
        case .difference:   return "CIDifferenceBlendMode"
        case .exclusion:    return "CIExclusionBlendMode"
        default:            return "CISourceOverCompositing"
        }
    }
}
