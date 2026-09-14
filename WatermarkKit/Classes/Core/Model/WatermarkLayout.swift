//
//  WatermarkLayout.swift
//  WatermarkKit
//

import CoreGraphics

/// 单个水印的布局描述，全部几何量归一化。
public struct WatermarkLayout: Sendable, Equatable {
    /// 定位方式。
    public enum Anchor: Sendable, Equatable {
        /// 九宫格预设。
        case preset(WatermarkPosition)
        /// 自定义归一化坐标（0...1，左上原点），指水印中心点的位置。
        case relative(CGPoint)
    }

    public var anchor: Anchor
    /// 归一化边距，仅对 `.preset` 生效；`.relative` 直接给定中心点，边距无意义。
    public var margin: RelativeInsets
    public var sizing: WatermarkSizing
    /// 旋转角度，单位弧度，绕水印自身中心旋转。
    public var rotation: CGFloat
    /// 平铺配置，`nil` 表示单个水印。
    public var tiling: WatermarkTiling?
    /// 叠加顺序，值越大越靠上。多水印场景必填，避免渲染顺序不确定。
    public var zIndex: Int

    public init(
        anchor: Anchor = .preset(.bottomRight),
        margin: RelativeInsets = .all(0.04),
        sizing: WatermarkSizing = .relativeShorterEdge(0.18),
        rotation: CGFloat = 0,
        tiling: WatermarkTiling? = nil,
        zIndex: Int = 0
    ) {
        self.anchor = anchor
        self.margin = margin
        self.sizing = sizing
        self.rotation = rotation
        self.tiling = tiling
        self.zIndex = zIndex
    }
}

/// 单个水印的视觉样式。
public struct WatermarkStyle: Sendable, Equatable {
    /// 不透明度，0...1。
    public var opacity: CGFloat
    public var blendMode: CGBlendMode

    public init(opacity: CGFloat = 0.85, blendMode: CGBlendMode = .normal) {
        self.opacity = opacity
        self.blendMode = blendMode
    }

    public static let `default` = WatermarkStyle()
}

/// 一个完整的水印条目：画什么 + 画在哪 + 怎么画。
public struct WatermarkItem: @unchecked Sendable {
    public var content: WatermarkContent
    public var layout: WatermarkLayout
    public var style: WatermarkStyle

    public init(
        content: WatermarkContent,
        layout: WatermarkLayout = WatermarkLayout(),
        style: WatermarkStyle = .default
    ) {
        self.content = content
        self.layout = layout
        self.style = style
    }
}
