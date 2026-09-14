//
//  ImageEncoder.swift
//  WatermarkKit
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 图片编码，负责格式降级与元数据处理。
///
/// 不使用 `UIImage.jpegData(compressionQuality:)` —— 它会丢弃全部 EXIF / TIFF / GPS，
/// 而「加完水印照片拍摄日期没了」是典型用户投诉。这里统一走 `CGImageDestination`
/// 手动拷贝元数据字典。
enum ImageEncoder {

    struct Encoded {
        let data: Data
        let format: WatermarkImageFormat
        let didFallbackFromHEIC: Bool
        let metadataPreserved: Bool
    }

    /// 当前设备是否支持 HEIC 编码。
    ///
    /// A9 及更早设备、部分模拟器只能解码不能编码，此时必须降级为 JPEG。
    static let isHEICEncodingSupported: Bool = {
        guard let buffer = CFDataCreateMutable(nil, 0) else { return false }
        return CGImageDestinationCreateWithData(
            buffer,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) != nil
    }()

    static func encode(
        _ cgImage: CGImage,
        format requestedFormat: WatermarkImageFormat,
        sourceMetadata: [CFString: Any]?,
        preservesMetadata: Bool,
        preservesLocation: Bool
    ) throws -> Encoded {
        var format = requestedFormat
        var didFallback = false
        if case .heic(let quality) = requestedFormat, !isHEICEncodingSupported {
            format = .jpeg(quality: quality)
            didFallback = true
        }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            format.utType,
            1,
            nil
        ) else {
            throw WatermarkError.encodingFailed("无法为 \(format.fileExtension) 创建 CGImageDestination")
        }

        let properties = imageProperties(
            cgImage: cgImage,
            format: format,
            sourceMetadata: sourceMetadata,
            preservesMetadata: preservesMetadata,
            preservesLocation: preservesLocation
        )
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw WatermarkError.encodingFailed("CGImageDestinationFinalize 失败（\(format.fileExtension)）")
        }

        let metadataPreserved = preservesMetadata && sourceMetadata != nil
        return Encoded(
            data: buffer as Data,
            format: format,
            didFallbackFromHEIC: didFallback,
            metadataPreserved: metadataPreserved
        )
    }

    /// 从原始编码数据中读取元数据字典。
    static func readMetadata(from data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return properties
    }

    // MARK: - 元数据组装

    private static func imageProperties(
        cgImage: CGImage,
        format: WatermarkImageFormat,
        sourceMetadata: [CFString: Any]?,
        preservesMetadata: Bool,
        preservesLocation: Bool
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]

        if preservesMetadata, let sourceMetadata {
            properties = sourceMetadata
            if !preservesLocation {
                // GPS 属隐私敏感项：加水印后的图片多用于分享，默认不把位置一起发出去
                properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }
            // 缩略图往往还是加水印前的旧图，留着会误导预览
            properties.removeValue(forKey: kCGImagePropertyThumbnailImages)
        }

        if let quality = format.compressionQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // 像素已在渲染阶段正过来了，方向必须重置为 up，否则解码方会二次旋转
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        properties[kCGImagePropertyPixelWidth] = cgImage.width
        properties[kCGImagePropertyPixelHeight] = cgImage.height

        // 顶层方向改了，EXIF / TIFF 子字典里的旧方向也要同步，否则部分解码器仍按旧值旋转
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }
}
