//
//  WatermarkSettings.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import UIKit
import WatermarkKit

/// Demo 提供的四种水印玩法。
enum WatermarkPreset: Int, CaseIterable {
    case logo
    case tiled
    case timestamp
    case combined

    var title: String {
        switch self {
        case .logo:         return "角标"
        case .tiled:        return "平铺"
        case .timestamp:    return "时间戳"
        case .combined:     return "叠加"
        }
    }

    /// 平铺水印铺满整个画面，位置与边距对它无从谈起。
    ///
    /// 这不是约定而是硬事实：`LayoutResolver` 解析带 `tiling` 的条目时直接走平铺网格，
    /// `anchor` 与 `margin` 算出来的中心点会被丢弃。
    var supportsPlacement: Bool { self != .tiled }

    /// 位置控件下方的说明文案。
    var placementHint: String {
        switch self {
        case .tiled:        return "平铺水印铺满画布，位置与边距不适用"
        case .combined:     return "位置与边距作用于右下角标，平铺层不受影响"
        case .logo, .timestamp: return "九宫格快速定位，或直接在预览图上拖动水印"
        }
    }
}

/// 定位方式。
enum PlacementMode: Int {
    /// 九宫格预设，边距生效。
    case grid
    /// 在预览图上拖出来的自由坐标，边距被库忽略。
    case free
}

/// 界面上可调的水印参数，`makeConfig` 负责翻译成库认识的 `WatermarkConfig`。
///
/// 之所以不直接持有 `WatermarkConfig`：`WatermarkItem` 里装着 `UIImage`，
/// 拖拽时每帧复制一份配置不划算，而 UI 真正要调的只有下面这几个标量。
struct WatermarkSettings {

    var preset: WatermarkPreset = .logo
    var mode: PlacementMode = .grid

    /// 九宫格模式的位置，与 `freePoint` 各存各的 —— 来回切模式不丢用户已经调好的值。
    var gridPosition: WatermarkPosition = .bottomRight
    /// 自由模式下的水印中心点（0...1，左上原点），语义与 `Anchor.relative` 一致。
    var freePoint = CGPoint(x: 0.82, y: 0.88)

    /// 归一化水平边距，写进 `RelativeInsets.left` / `.right`。
    var marginX: CGFloat = 0.04
    /// 归一化垂直边距，写进 `RelativeInsets.top` / `.bottom`。
    var marginY: CGFloat = 0.04

    /// 时间戳预设烧录的时间。
    ///
    /// `WatermarkConfig.timestamp` 默认取 `Date()`，而拖拽时每帧都会重建配置，
    /// 跨分钟的那一刻预览文字会突然跳变。固定到会话开始时刻，预览才稳定。
    let sessionDate = Date()

    var supportsPlacement: Bool { preset.supportsPlacement }

    /// 角标水印相对画布短边的占比。
    static let badgeSizeRatio: CGFloat = 0.18
    /// 叠加预设里角标略大一点，与库文档的示例保持一致。
    static let combinedBadgeSizeRatio: CGFloat = 0.2
    /// 时间戳文字条相对画布宽度的占比。
    static let timestampWidthRatio: CGFloat = 0.3
    /// 单行时间戳文字的高宽比估算值，仅用于拖拽边界约束。
    static let timestampAspect: CGFloat = 0.2

    // MARK: - 配置构造

    /// - Parameter destination: 必须显式指定 —— 预览用 `.memoryOnly` 跳过编码，
    ///   导出用 `.temporary` 才能拿到可分享的文件；视频侧更是明确拒绝 `.memoryOnly`。
    func makeConfig(logo: UIImage, destination: WatermarkDestination) -> WatermarkConfig {
        var config = baseConfig(logo: logo)
        applyPlacement(to: &config)
        config.output.destination = destination
        return config
    }

    private func baseConfig(logo: UIImage) -> WatermarkConfig {
        switch preset {
        case .logo:
            return .bottomRightLogo(logo, sizeRatio: Self.badgeSizeRatio)

        case .tiled:
            return .tiledText("WatermarkKit")

        case .timestamp:
            return .timestamp(date: sessionDate, position: .bottomLeft)

        case .combined:
            // 多水印叠加：zIndex 决定谁压在上面
            var config = WatermarkConfig.tiledText("样例", opacity: 0.12)
            config.items[0].layout.zIndex = 0
            config.items.append(
                WatermarkItem(
                    content: .image(logo),
                    layout: WatermarkLayout(
                        anchor: .preset(.bottomRight),
                        sizing: .relativeShorterEdge(Self.combinedBadgeSizeRatio),
                        zIndex: 1
                    )
                )
            )
            return config
        }
    }

    /// 把位置与边距写回所有「非平铺」条目。
    ///
    /// 判据用 `layout.tiling == nil`：叠加预设下命中的正是压在最上层的角标 —— 用户拖的就是它；
    /// 平铺预设下不存在这样的条目，位置与边距自然不生效，UI 侧会同步置灰。
    private func applyPlacement(to config: inout WatermarkConfig) {
        guard supportsPlacement else { return }

        for index in config.items.indices where config.items[index].layout.tiling == nil {
            switch mode {
            case .grid:
                config.items[index].layout.anchor = .preset(gridPosition)
                config.items[index].layout.margin = RelativeInsets(
                    top: marginY,
                    left: marginX,
                    bottom: marginY,
                    right: marginX
                )

            case .free:
                config.items[index].layout.anchor = .relative(freePoint)
                // `.relative` 下库本就忽略 margin，置零让配置自洽
                config.items[index].layout.margin = .zero
            }
        }
    }

    // MARK: - 拖拽边界

    /// 把拖拽得到的中心点夹在画布内。
    ///
    /// 库对 `.relative` 锚点不做任何边界约束（中心点直接乘以画布尺寸），
    /// 而 `.preset` 分支是有外接矩形约束的。拖到边上水印就会被裁掉一半，
    /// 所以这道约束必须由调用方来把。
    func clampedCenter(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return point }
        let size = estimatedWatermarkSize(canvasSize: canvasSize)
        let halfX = min(size.width / canvasSize.width / 2, 0.5)
        let halfY = min(size.height / canvasSize.height / 2, 0.5)
        return CGPoint(
            x: min(max(point.x, halfX), 1 - halfX),
            y: min(max(point.y, halfY), 1 - halfY)
        )
    }

    /// 可定位水印的外接尺寸估算。
    ///
    /// 精确值要跑一遍光栅化才知道，但这里只服务于「别把水印拖出画面」，估算足够。
    private func estimatedWatermarkSize(canvasSize: CGSize) -> CGSize {
        let shorterEdge = min(canvasSize.width, canvasSize.height)

        switch preset {
        case .tiled:
            return .zero
        case .logo:
            let base = shorterEdge * Self.badgeSizeRatio
            return CGSize(width: base, height: base)
        case .combined:
            let base = shorterEdge * Self.combinedBadgeSizeRatio
            return CGSize(width: base, height: base)
        case .timestamp:
            let width = canvasSize.width * Self.timestampWidthRatio
            return CGSize(width: width, height: width * Self.timestampAspect)
        }
    }
}
