//
//  ImageWatermarkRenderer.swift
//  WatermarkKit
//

import ImageIO
import UIKit

/// 图片水印渲染器。
///
/// 全程在像素空间工作（渲染上下文 `scale = 1`，画布尺寸取图片的真实像素尺寸），
/// 这样文字光栅化不会经历「按 point 渲染再被上下文放大」的二次采样，任何分辨率下字形都清晰。
public struct ImageWatermarkRenderer: ImageWatermarkRendering {

    public init() {}

    public func applyWatermark(
        to source: ImageSource,
        config: WatermarkConfig
    ) async throws -> ImageWatermarkResult {
        try Task.checkCancellation()

        let decoded = try Self.decode(source)
        let canvasSize = decoded.pixelSize

        let placements = try LayoutResolver.resolve(config: config, canvasSize: canvasSize)
        try Task.checkCancellation()

        let rendered = Self.draw(base: decoded.image, canvasSize: canvasSize, placements: placements)
        guard let renderedCGImage = rendered.cgImage else {
            throw WatermarkError.encodingFailed("渲染结果无法取得 CGImage")
        }
        try Task.checkCancellation()

        return try Self.finish(
            rendered: rendered,
            cgImage: renderedCGImage,
            metadata: decoded.metadata,
            config: config
        )
    }

    // MARK: - 解码

    private struct Decoded {
        let image: UIImage
        let pixelSize: CGSize
        let metadata: [CFString: Any]?
    }

    private static func decode(_ source: ImageSource) throws -> Decoded {
        switch source {
        case .image(let image):
            return Decoded(image: image, pixelSize: image.pixelSize, metadata: nil)

        case .data(let data):
            guard let image = UIImage(data: data) else {
                throw WatermarkError.unsupportedFormat("无法解码传入的图片数据")
            }
            return Decoded(image: image, pixelSize: image.pixelSize, metadata: ImageEncoder.readMetadata(from: data))

        case .fileURL(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WatermarkError.fileNotFound(url)
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw WatermarkError.unsupportedFormat("读取失败：\(error.localizedDescription)")
            }
            guard let image = UIImage(data: data) else {
                throw WatermarkError.unsupportedFormat("无法解码 \(url.lastPathComponent)")
            }
            return Decoded(image: image, pixelSize: image.pixelSize, metadata: ImageEncoder.readMetadata(from: data))
        }
    }

    // MARK: - 绘制

    private static func draw(
        base: UIImage,
        canvasSize: CGSize,
        placements: [ResolvedPlacement]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1                    // 画布已是像素尺寸，再乘屏幕倍率会导致二次放大
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            // UIImage.draw 会自动应用 imageOrientation，画进来的就是用户看到的方向
            base.draw(in: CGRect(origin: .zero, size: canvasSize))
            // 与视频侧共用同一段绘制，两种介质的输出因此逐像素一致
            WatermarkCompositor.draw(placements, into: context.cgContext)
        }
    }

    // MARK: - 输出

    private static func finish(
        rendered: UIImage,
        cgImage: CGImage,
        metadata: [CFString: Any]?,
        config: WatermarkConfig
    ) throws -> ImageWatermarkResult {
        let output = config.output

        // 只要内存图，且不需要写文件，就没必要跑一遍编解码
        if case .memoryOnly = output.destination {
            return ImageWatermarkResult(
                image: rendered,
                actualFormat: output.imageFormat,
                didFallbackFromHEIC: false,
                metadataPreserved: false
            )
        }

        let encoded = try ImageEncoder.encode(
            cgImage,
            format: output.imageFormat,
            sourceMetadata: metadata,
            preservesMetadata: output.preservesMetadata,
            preservesLocation: output.preservesLocation
        )

        let url = try destinationURL(for: output.destination, fileExtension: encoded.format.fileExtension)
        do {
            try encoded.data.write(to: url, options: .atomic)
        } catch {
            TemporaryFileManager.shared.discard(url)
            throw WatermarkError.outputPathNotWritable(url, underlying: error)
        }

        return ImageWatermarkResult(
            image: rendered,
            fileURL: url,
            actualFormat: encoded.format,
            didFallbackFromHEIC: encoded.didFallbackFromHEIC,
            metadataPreserved: encoded.metadataPreserved
        )
    }

    private static func destinationURL(
        for destination: WatermarkDestination,
        fileExtension: String
    ) throws -> URL {
        switch destination {
        case .memoryOnly:
            // 上游已提前返回，走到这里说明调用链有问题
            throw WatermarkError.invalidConfiguration("memoryOnly 不应请求输出路径")
        case .file(let url):
            let directory = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw WatermarkError.outputPathNotWritable(url, underlying: error)
            }
            return url
        case .temporary:
            return try TemporaryFileManager.shared.makeURL(fileExtension: fileExtension)
        }
    }
}

private extension UIImage {
    /// 真实像素尺寸（`size` 是 point，需乘以 `scale`）。
    var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
