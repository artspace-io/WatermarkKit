//
//  WatermarkSource.swift
//  WatermarkKit
//

import AVFoundation
import UIKit

/// 图片输入。
///
/// 之所以不只收 `UIImage`：元数据保留需要原始编码数据 —— `UIImage` 在解码时就已经把
/// EXIF / GPS 丢掉了。只有 `.fileURL` / `.data` 能走通「保留拍摄时间」这条需求。
public enum ImageSource: @unchecked Sendable {
    case image(UIImage)
    case fileURL(URL)
    case data(Data)

    /// 是否可能携带原始元数据。
    var canCarryMetadata: Bool {
        switch self {
        case .image:                 return false
        case .fileURL, .data:        return true
        }
    }

    var fileURL: URL? {
        if case .fileURL(let url) = self { return url }
        return nil
    }
}

/// 视频输入。
///
/// 核心库只认 `URL` 与 `AVAsset`。`PHAsset` 由 `WatermarkKit/Photos` subspec 通过适配层
/// 转换成 `.asset` 后传入，枚举里不出现跨 subspec 的 case，模块边界更干净。
public enum VideoSource: @unchecked Sendable {
    case url(URL)
    case asset(AVAsset)

    var fileURL: URL? {
        switch self {
        case .url(let url):                 return url
        case .asset(let asset):             return (asset as? AVURLAsset)?.url
        }
    }

    /// 解析为可直接处理的 `AVAsset`，并顺带做文件存在性校验。
    func resolveAsset() throws -> AVAsset {
        switch self {
        case .url(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WatermarkError.fileNotFound(url)
            }
            return AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        case .asset(let asset):
            return asset
        }
    }
}
