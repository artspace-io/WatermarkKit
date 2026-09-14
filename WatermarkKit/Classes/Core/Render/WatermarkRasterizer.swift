//
//  WatermarkRasterizer.swift
//  WatermarkKit
//

import UIKit

/// 把水印内容光栅化成位图。
///
/// 图片与视频两条管线共用这一层，保证同一份配置在两种介质上渲染结果视觉一致。
///
/// 文字不用 `CATextLayer` —— 后者对描边、阴影、多行截断的支持都很有限。
/// 改为用 TextKit 预渲染成位图，描边 / 阴影 / 换行全部交给 `NSAttributedString`。
enum WatermarkRasterizer {

    /// 光栅化产物。
    struct Raster {
        let image: CGImage
        /// 位图对应的绘制尺寸（point），即水印在画布上占据的实际大小。
        let size: CGSize
    }

    /// 内容的固有尺寸，用于 `WatermarkSizing` 推导目标尺寸。
    static func intrinsicSize(of content: WatermarkContent, canvasSize: CGSize) throws -> CGSize {
        switch content {
        case .image(let image):
            let size = image.size
            guard size.width > 0, size.height > 0 else {
                throw WatermarkError.invalidWatermarkContent("水印图片尺寸为 0")
            }
            return size
        case .text(let string, let attributes):
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatermarkError.invalidWatermarkContent("水印文字为空")
            }
            return textBoundingSize(string, attributes: attributes, canvasSize: canvasSize)
        }
    }

    /// 按目标尺寸光栅化。
    ///
    /// 文字会按缩放比例重新排版（而非拉伸位图），保证任何分辨率下字形都是清晰的。
    static func rasterize(
        _ content: WatermarkContent,
        targetSize: CGSize,
        canvasSize: CGSize
    ) throws -> Raster {
        switch content {
        case .image(let image):
            guard let cgImage = image.cgImage ?? image.ciImageBackedCGImage else {
                throw WatermarkError.invalidWatermarkContent("水印图片无法取得 CGImage")
            }
            return Raster(image: cgImage, size: targetSize)

        case .text(let string, let attributes):
            let intrinsic = textBoundingSize(string, attributes: attributes, canvasSize: canvasSize)
            guard intrinsic.width > 0 else {
                throw WatermarkError.invalidWatermarkContent("水印文字排版结果为空")
            }
            // 按目标宽度反推字号重新排版，而不是把小位图拉大
            let scale = max(targetSize.width / intrinsic.width, 0.01)
            var scaled = attributes
            scaled.font = attributes.font.withSize(attributes.font.pointSize * scale)
            if let shadow = attributes.shadow {
                scaled.shadow = TextShadow(
                    offset: CGSize(width: shadow.offset.width * scale, height: shadow.offset.height * scale),
                    blurRadius: shadow.blurRadius * scale,
                    color: shadow.color
                )
            }
            scaled.strokeWidth = attributes.strokeWidth    // 百分比语义，不随字号缩放

            let finalSize = textBoundingSize(string, attributes: scaled, canvasSize: canvasSize)
            guard let cgImage = drawText(string, attributes: scaled, size: finalSize) else {
                throw WatermarkError.invalidWatermarkContent("水印文字渲染失败")
            }
            return Raster(image: cgImage, size: finalSize)
        }
    }

    // MARK: - 文字排版

    private static func textBoundingSize(
        _ string: String,
        attributes: TextAttributes,
        canvasSize: CGSize
    ) -> CGSize {
        let attributed = NSAttributedString(string: string, attributes: attributes.attributedStringAttributes)
        let maxWidth = canvasSize.width > 0
            ? canvasSize.width * max(0.05, min(attributes.maxWidthRatio, 1))
            : CGFloat.greatestFiniteMagnitude
        let constraint = CGSize(
            width: attributes.maxLines == 1 ? .greatestFiniteMagnitude : maxWidth,
            height: .greatestFiniteMagnitude
        )
        var rect = attributed.boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        if attributes.maxLines > 0 {
            let lineHeight = attributes.font.lineHeight
            rect.size.height = min(rect.height, lineHeight * CGFloat(attributes.maxLines))
        }
        // 描边与阴影会溢出文字排版框，留出外扩空间避免被裁切
        let bleed = textBleed(for: attributes)
        return CGSize(
            width: ceil(rect.width) + bleed.width * 2,
            height: ceil(rect.height) + bleed.height * 2
        )
    }

    private static func textBleed(for attributes: TextAttributes) -> CGSize {
        let strokeBleed = abs(attributes.strokeWidth) / 100 * attributes.font.pointSize
        guard let shadow = attributes.shadow else {
            return CGSize(width: strokeBleed, height: strokeBleed)
        }
        return CGSize(
            width: strokeBleed + shadow.blurRadius + abs(shadow.offset.width),
            height: strokeBleed + shadow.blurRadius + abs(shadow.offset.height)
        )
    }

    private static func drawText(_ string: String, attributes: TextAttributes, size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1                 // 已按目标像素尺寸排版，无需再乘屏幕倍率

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let attributed = NSAttributedString(string: string, attributes: attributes.attributedStringAttributes)
            let bleed = textBleed(for: attributes)
            let drawRect = CGRect(
                x: bleed.width,
                y: bleed.height,
                width: size.width - bleed.width * 2,
                height: size.height - bleed.height * 2
            )
            if let shadow = attributes.shadow {
                context.cgContext.setShadow(
                    offset: shadow.offset,
                    blur: shadow.blurRadius,
                    color: shadow.color.cgColor
                )
            }
            attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return image.cgImage
    }
}

private extension TextAttributes {
    /// 转换为 `NSAttributedString` 属性字典。
    var attributedStringAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode

        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if let strokeColor {
            result[.strokeColor] = strokeColor
            result[.strokeWidth] = strokeWidth
        }
        return result
    }
}

private extension UIImage {
    /// `UIImage` 由 `CIImage` 支撑时（滤镜产物）没有 `cgImage`，这里补一次渲染。
    var ciImageBackedCGImage: CGImage? {
        guard let ciImage else { return nil }
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }
}
