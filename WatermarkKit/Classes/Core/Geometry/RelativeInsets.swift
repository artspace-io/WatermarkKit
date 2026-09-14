//
//  RelativeInsets.swift
//  WatermarkKit
//

import CoreGraphics

/// 归一化边距。
///
/// 取值为 0...1 的比例：`left` / `right` 相对画布宽度，`top` / `bottom` 相对画布高度。
/// 需求文档要求「不出现任何像素常量」，因此边距同样以比例表达，
/// 这样同一份配置在 1080p 与 4K 素材上得到视觉一致的结果。
public struct RelativeInsets: Sendable, Equatable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = RelativeInsets()

    /// 四边等距。
    public static func all(_ value: CGFloat) -> RelativeInsets {
        RelativeInsets(top: value, left: value, bottom: value, right: value)
    }

    /// 换算为指定画布尺寸下的像素边距。
    func resolved(in canvasSize: CGSize) -> UIEdgeInsetsLike {
        UIEdgeInsetsLike(
            top: top * canvasSize.height,
            left: left * canvasSize.width,
            bottom: bottom * canvasSize.height,
            right: right * canvasSize.width
        )
    }
}

/// 内部使用的像素边距，避免核心几何层直接依赖 UIKit。
struct UIEdgeInsetsLike: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
}
