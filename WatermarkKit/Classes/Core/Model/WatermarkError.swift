//
//  WatermarkError.swift
//  WatermarkKit
//

import AVFoundation
import Foundation

/// 水印处理过程中可能抛出的错误。
///
/// 每个 case 都携带足以定位问题的上下文（源路径、底层 `Error`），便于线上排查。
public enum WatermarkError: Error, @unchecked Sendable {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    /// 输入是纯音频文件或视频轨道缺失。
    case noVideoTrack(URL?)
    /// 资产不可读，通常是 DRM 保护内容。
    case assetNotReadable(URL?)
    /// iCloud 资源下载失败：网络不可用、未开启 iCloud 照片、资源已从设备移除等。
    case iCloudDownloadFailed(underlying: Error?)
    /// 水印素材本身非法：空图、尺寸为 0、文字为空等。
    case invalidWatermarkContent(String)
    case outputPathNotWritable(URL, underlying: Error?)
    case exportFailed(underlying: Error?)
    /// 磁盘空间不足。
    ///
    /// 不做事前精确检查（拿不准且存在 TOCTOU 问题），而是把 `AVError.diskFull` 事后映射过来；
    /// 事前仅用 `estimatedOutputFileLength` 做粗筛提示。
    case diskFull
    /// 来电、长时间后台等系统级中断。
    case interrupted
    case cancelled
    /// 无水印条目，或配置与输入类型不匹配。
    case invalidConfiguration(String)
    /// 图片编码失败。
    case encodingFailed(String)

    /// 是否属于「用户主动取消」。
    ///
    /// 取消不是故障，UI 不该按失败提示 —— 但取消可能由 `Task.cancel()` 触发，
    /// 抛出的既可能是本枚举也可能是 `CancellationError`，判定逻辑留在这里免得各调用方各写一份。
    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// 把 AVFoundation 抛出的错误映射到本枚举，把 `diskFull` 这类可识别原因提取出来。
    static func mapping(_ error: Error?) -> WatermarkError {
        guard let error else { return .exportFailed(underlying: nil) }
        if let watermarkError = error as? WatermarkError { return watermarkError }
        // 结构化并发的取消抛的是 CancellationError，落到 exportFailed 会被 UI 当成故障提示
        if error is CancellationError { return .cancelled }

        guard let avError = error as? AVError else {
            return .exportFailed(underlying: error)
        }
        switch avError.code {
        case .diskFull:
            return .diskFull
        case .operationInterrupted, .mediaServicesWereReset:
            return .interrupted
        case .contentIsProtected, .contentIsNotAuthorized:
            return .assetNotReadable(nil)
        case .decoderNotFound, .undecodableMediaData, .invalidSourceMedia, .noLongerPlayable:
            return .unsupportedFormat(avError.localizedDescription)
        default:
            return .exportFailed(underlying: error)
        }
    }
}

extension WatermarkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "文件不存在：\(url.path)"
        case .unsupportedFormat(let detail):
            return "不支持的格式：\(detail)"
        case .noVideoTrack(let url):
            return "素材不含视频轨道\(url.map { "：\($0.lastPathComponent)" } ?? "")"
        case .assetNotReadable(let url):
            return "素材不可读，可能受 DRM 保护\(url.map { "：\($0.lastPathComponent)" } ?? "")"
        case .iCloudDownloadFailed(let underlying):
            return "iCloud 资源下载失败\(underlying.map { "：\($0.localizedDescription)" } ?? "")"
        case .invalidWatermarkContent(let detail):
            return "水印内容非法：\(detail)"
        case .outputPathNotWritable(let url, let underlying):
            return "输出路径不可写：\(url.path)\(underlying.map { "（\($0.localizedDescription)）" } ?? "")"
        case .exportFailed(let underlying):
            return "导出失败\(underlying.map { "：\($0.localizedDescription)" } ?? "")"
        case .diskFull:
            return "磁盘空间不足"
        case .interrupted:
            return "处理被系统中断"
        case .cancelled:
            return "处理已取消"
        case .invalidConfiguration(let detail):
            return "配置非法：\(detail)"
        case .encodingFailed(let detail):
            return "图片编码失败：\(detail)"
        }
    }
}
