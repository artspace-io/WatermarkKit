//
//  WatermarkTiling.swift
//  WatermarkKit
//

import CoreGraphics

/// 平铺配置，用于防盗用场景。
public struct WatermarkTiling: Sendable, Equatable {
    /// 归一化间距（相对画布宽/高），指两个相邻水印中心点的距离。
    public var spacing: CGSize
    /// 整片平铺网格的倾斜角度，单位弧度。
    public var angle: CGFloat
    /// 奇数行是否错半格排列。
    public var isStaggered: Bool
    /// 平铺数量上限。
    ///
    /// 4K 画布上密集平铺可能生成数百个实例，光栅化与绘制的开销会显著上升。
    /// 超过上限时自动等比放大间距而不是截断，保证视觉仍然铺满，只是密度降低。
    public var maxTileCount: Int

    public init(
        spacing: CGSize = CGSize(width: 0.3, height: 0.2),
        angle: CGFloat = -.pi / 9,
        isStaggered: Bool = true,
        maxTileCount: Int = 200
    ) {
        self.spacing = spacing
        self.angle = angle
        self.isStaggered = isStaggered
        self.maxTileCount = max(1, maxTileCount)
    }
}
