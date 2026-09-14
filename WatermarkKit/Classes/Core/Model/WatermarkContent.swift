//
//  WatermarkContent.swift
//  WatermarkKit
//

import UIKit

/// 文字水印的排版与描边样式。
///
/// 说明：需求文档草案中此处为 `NSShadow`，实现时改用下方的 `TextShadow` 值类型 ——
/// `NSShadow` 是可变的引用类型且未标注 `Sendable`，放进配置模型会破坏全链路并发安全。
public struct TextAttributes: @unchecked Sendable {
    public var font: UIFont
    public var color: UIColor
    public var strokeColor: UIColor?
    /// 沿用 `NSAttributedString` 语义：正值仅描边，负值同时描边与填充。
    /// 描边水印通常需要「白字黑边」的效果，因此默认取负值。
    public var strokeWidth: CGFloat
    public var shadow: TextShadow?
    public var alignment: NSTextAlignment
    public var lineBreakMode: NSLineBreakMode
    /// 最大行数，0 表示不限制。
    public var maxLines: Int
    /// 排版宽度上限，相对画布宽度的比例；超出后按 `lineBreakMode` 换行或截断。
    public var maxWidthRatio: CGFloat

    public init(
        font: UIFont = .systemFont(ofSize: 64, weight: .semibold),
        color: UIColor = .white,
        strokeColor: UIColor? = nil,
        strokeWidth: CGFloat = -2,
        shadow: TextShadow? = .default,
        alignment: NSTextAlignment = .left,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        maxLines: Int = 1,
        maxWidthRatio: CGFloat = 0.9
    ) {
        self.font = font
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.alignment = alignment
        self.lineBreakMode = lineBreakMode
        self.maxLines = maxLines
        self.maxWidthRatio = maxWidthRatio
    }
}

/// 文字阴影，`NSShadow` 的 `Sendable` 替代。
public struct TextShadow: @unchecked Sendable, Equatable {
    public var offset: CGSize
    public var blurRadius: CGFloat
    public var color: UIColor

    public init(
        offset: CGSize = CGSize(width: 0, height: 1),
        blurRadius: CGFloat = 3,
        color: UIColor = .black.withAlphaComponent(0.5)
    ) {
        self.offset = offset
        self.blurRadius = blurRadius
        self.color = color
    }

    /// 通用的轻微投影，保证浅色背景上的白字仍然可读。
    public static let `default` = TextShadow()
}

/// 水印内容。
public enum WatermarkContent: @unchecked Sendable {
    case text(String, attributes: TextAttributes)
    case image(UIImage)

    /// 便利构造：使用默认排版的纯文字水印。
    public static func text(_ string: String) -> WatermarkContent {
        .text(string, attributes: TextAttributes())
    }
}
