//
//  MediaPicker.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import AVFoundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import WatermarkKit

/// 一份待加水印的素材。
struct MediaItem {

    enum Kind {
        /// 冷启动时的内置演示图，不来自相册。
        case sample
        case photo
        case video
    }

    let kind: Kind
    /// 相册素材拷贝到临时目录后的路径；`.sample` 为 nil。
    let sourceURL: URL?
    /// `.sample` 的全尺寸底图，相册素材不需要（导出直接读 `sourceURL`）。
    let fullImage: UIImage?
    /// 用于预览的小图：最长边 `MediaLoader.previewMaxPixel`，scale 1、方向已摆正。
    let previewBase: UIImage

    var isVideo: Bool { kind == .video }

    /// 导出时用的图片输入。
    ///
    /// 相册照片一律走 `.fileURL` 而不是 `.image` —— `UIImage` 在解码那一刻就把 EXIF 丢了，
    /// 只有原始文件这条路径 `preservesMetadata` 才可能真生效。
    var imageSource: ImageSource? {
        if let sourceURL { return .fileURL(sourceURL) }
        if let fullImage { return .image(fullImage) }
        return nil
    }

    var videoSource: VideoSource? {
        guard isVideo, let sourceURL else { return nil }
        return .url(sourceURL)
    }

    var summary: String {
        let size = previewBase.size
        switch kind {
        case .sample:   return "内置演示图"
        case .photo:    return "照片 · 预览 \(Int(size.width))×\(Int(size.height))"
        case .video:    return "视频 · 首帧 \(Int(size.width))×\(Int(size.height))"
        }
    }
}

enum MediaLoaderError: LocalizedError {
    case unsupported
    case loadFailed(String)
    case frameUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported:              return "不支持的素材类型"
        case .loadFailed(let reason):   return "载入失败：\(reason)"
        case .frameUnavailable:         return "取不到视频首帧"
        }
    }
}

/// 把 `PHPickerResult` 变成可用的 `MediaItem`。
enum MediaLoader {

    /// 预览底图的最长边。
    ///
    /// 取 1024 而不是更小：`TextAttributes.maxWidthRatio` 是相对画布宽度的，
    /// 画布太小时文字水印可能在预览里被截断、原图上却不会，预览就失真了。
    static let previewMaxPixel: CGFloat = 1024

    static func load(_ provider: NSItemProvider) async throws -> MediaItem {
        // 先判视频：部分素材两个 UTType 都会命中
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let url = try await copyToTemporary(provider, typeIdentifier: UTType.movie.identifier)
            let frame = try await firstFrame(of: url)
            return MediaItem(kind: .video, sourceURL: url, fullImage: nil, previewBase: frame)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await copyToTemporary(provider, typeIdentifier: UTType.image.identifier)
            guard let thumbnail = thumbnail(at: url) else {
                throw MediaLoaderError.loadFailed("无法解码所选图片")
            }
            return MediaItem(kind: .photo, sourceURL: url, fullImage: nil, previewBase: thumbnail)
        }

        throw MediaLoaderError.unsupported
    }

    // MARK: - 拷贝

    /// `loadFileRepresentation` 的临时文件在回调返回后即被系统删除，必须在闭包内同步拷走。
    private static func copyToTemporary(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    let reason = error?.localizedDescription ?? "未知错误"
                    continuation.resume(throwing: MediaLoaderError.loadFailed(reason))
                    return
                }

                let fileExtension = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked-\(UUID().uuidString).\(fileExtension)")
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: MediaLoaderError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - 缩略图

    /// 直接由 `CGImageSource` 出缩略图，避免「解全图再缩」的内存峰值。
    static func thumbnail(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 应用 EXIF 方向，省得后面再跟 UIImage.orientation 纠缠
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// 抽取视频首帧作为预览底图。
    ///
    /// `appliesPreferredTrackTransform` 与库内部对 `preferredTransform` 的归一化语义一致，
    /// 所以「首帧上看到的水印位置」就是「导出结果里的位置」。
    static func firstFrame(of url: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewMaxPixel, height: previewMaxPixel)
        generator.requestedTimeToleranceBefore = .zero
        // 容忍到后面的关键帧，比强求第 0 帧快得多，对「看位置」没有影响
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        } catch {
            throw MediaLoaderError.frameUnavailable
        }
    }

    /// 把内置演示图缩到预览尺寸。
    static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > previewMaxPixel else { return image }

        let scale = previewMaxPixel / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// `PHPickerViewController` 的薄封装，一次选一个素材，图片和视频都收。
final class MediaPicker: NSObject {

    private var completion: (@MainActor (Result<MediaItem, Error>) -> Void)?

    func present(
        from viewController: UIViewController,
        completion: @escaping @MainActor (Result<MediaItem, Error>) -> Void
    ) {
        self.completion = completion

        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        // 不让系统转码：`.compatible` 会把 HEIC 转成 JPEG 并重写元数据，
        // 正好破坏我们想演示的「保留 EXIF」
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        viewController.present(picker, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension MediaPicker: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        let callback = completion
        completion = nil

        // 用户直接取消，什么都不用做
        guard let provider = results.first?.itemProvider else { return }

        // `MediaLoader.load` 不带隔离，await 时自动跳到后台执行器；
        // 回调则固定落在主线程上
        Task { @MainActor in
            do {
                callback?(.success(try await MediaLoader.load(provider)))
            } catch {
                callback?(.failure(error))
            }
        }
    }
}

// MARK: - 内置演示素材

/// 冷启动没有相册素材时用的占位图，选完素材后就用不到了。
enum SampleAssets {

    static func item() -> MediaItem {
        let image = background()
        return MediaItem(
            kind: .sample,
            sourceURL: nil,
            fullImage: image,
            previewBase: MediaLoader.downscaled(image)
        )
    }

    static func background() -> UIImage {
        let size = CGSize(width: 1080, height: 1440)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }

    static func logo() -> UIImage {
        let size = CGSize(width: 240, height: 240)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.withAlphaComponent(0.9).setFill()
            let path = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12),
                cornerRadius: 48
            )
            path.fill()
            let text = NSAttributedString(string: "WK", attributes: [
                .font: UIFont.systemFont(ofSize: 96, weight: .heavy),
                .foregroundColor: UIColor.systemIndigo
            ])
            let bounds = text.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
            text.draw(at: CGPoint(
                x: (size.width - bounds.width) / 2,
                y: (size.height - bounds.height) / 2
            ))
        }
    }
}
