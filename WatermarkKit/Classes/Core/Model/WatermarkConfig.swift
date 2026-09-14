//
//  WatermarkConfig.swift
//  WatermarkKit
//

import UIKit

/// 水印处理的完整配置。
///
/// 拆为「条目数组 + 全局导出配置」三层结构，而非单一扁平 struct ——
/// 多水印叠加需求决定了条目必须可以有任意多个，而导出参数全局唯一。
public struct WatermarkConfig: @unchecked Sendable {
    /// 水印条目，按 `layout.zIndex` 升序叠加。
    public var items: [WatermarkItem]
    public var output: OutputConfig
    public var video: VideoOutputConfig

    public init(
        items: [WatermarkItem],
        output: OutputConfig = .default,
        video: VideoOutputConfig = .default
    ) {
        self.items = items
        self.output = output
        self.video = video
    }

    /// 按 zIndex 排序后的条目，渲染层统一走这个入口，保证叠加顺序确定。
    var orderedItems: [WatermarkItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.layout.zIndex == rhs.element.layout.zIndex
                    ? lhs.offset < rhs.offset          // zIndex 相同时按声明顺序，保持稳定排序
                    : lhs.element.layout.zIndex < rhs.element.layout.zIndex
            }
            .map(\.element)
    }
}

// MARK: - 便利构造

public extension WatermarkConfig {

    /// 右下角图片水印 —— 最常见的 Logo 角标。
    static func bottomRightLogo(
        _ image: UIImage,
        sizeRatio: CGFloat = 0.18,
        margin: CGFloat = 0.04,
        opacity: CGFloat = 0.9
    ) -> WatermarkConfig {
        WatermarkConfig(items: [
            WatermarkItem(
                content: .image(image),
                layout: WatermarkLayout(
                    anchor: .preset(.bottomRight),
                    margin: .all(margin),
                    sizing: .relativeShorterEdge(sizeRatio)
                ),
                style: WatermarkStyle(opacity: opacity)
            )
        ])
    }

    /// 满屏斜向平铺文字 —— 防盗用场景。
    static func tiledText(
        _ text: String,
        attributes: TextAttributes = TextAttributes(font: .systemFont(ofSize: 48, weight: .medium)),
        opacity: CGFloat = 0.18,
        tiling: WatermarkTiling = WatermarkTiling()
    ) -> WatermarkConfig {
        WatermarkConfig(items: [
            WatermarkItem(
                content: .text(text, attributes: attributes),
                layout: WatermarkLayout(
                    anchor: .preset(.center),
                    margin: .zero,
                    sizing: .relativeWidth(0.22),
                    rotation: tiling.angle,
                    tiling: tiling
                ),
                style: WatermarkStyle(opacity: opacity)
            )
        ])
    }

    /// 处理时刻的静态时间戳。
    ///
    /// 注意这是「处理发生时」烧录的固定文本，不是随视频播放递增的时间码 ——
    /// 后者需要逐帧改变水印内容，当前的「预合成一张叠加图」方案做不到，属后续版本范围。
    static func timestamp(
        date: Date = Date(),
        formatter: DateFormatter? = nil,
        position: WatermarkPosition = .bottomRight,
        attributes: TextAttributes = TextAttributes()
    ) -> WatermarkConfig {
        let text = (formatter ?? WatermarkConfig.defaultTimestampFormatter).string(from: date)
        return WatermarkConfig(items: [
            WatermarkItem(
                content: .text(text, attributes: attributes),
                layout: WatermarkLayout(anchor: .preset(position), sizing: .relativeWidth(0.3))
            )
        ])
    }

    private static let defaultTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
