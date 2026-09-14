//
//  PhotosAdapter.swift
//  WatermarkKit/Photos
//

import AVFoundation
import Photos
import UIKit

/// `PHAsset` → 核心库输入类型的适配层。
///
/// 核心库刻意不认识 `PHAsset`：纯 AI 生成场景（素材来自网络或本地生成，根本不碰相册）
/// 不应该被迫在 Info.plist 里声明相册权限。相册场景引入本 subspec 即可，
/// 同时也不必每个调用方重写一遍 iCloud 下载与进度合并。
public enum PhotosAdapter {

    /// 从 `PHAsset` 取得可处理的视频资产。
    ///
    /// 资源可能只存在于 iCloud，此时会触发下载，`downloadProgress` 回报 0...1。
    public static func videoSource(
        from asset: PHAsset,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoSource {
        guard asset.mediaType == .video else {
            throw WatermarkError.unsupportedFormat("PHAsset 不是视频类型")
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true          // 允许从 iCloud 下载
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { progress, _, _, _ in
            downloadProgress?(progress)
        }

        return try await request { complete in
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, info in
                if let error = Self.error(from: info) {
                    return complete(.failure(error))
                }
                guard let avAsset else {
                    return complete(.failure(.iCloudDownloadFailed(underlying: nil)))
                }
                downloadProgress?(1)
                complete(.success(.asset(avAsset)))
            }
        }
    }

    /// 从 `PHAsset` 取得图片输入。
    ///
    /// 返回 `.data` 而不是 `.image` —— 原始编码数据才带得动 EXIF / GPS，
    /// 解成 `UIImage` 的那一刻元数据就没了，`preservesMetadata` 也就无从谈起。
    public static func imageSource(
        from asset: PHAsset,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ImageSource {
        guard asset.mediaType == .image else {
            throw WatermarkError.unsupportedFormat("PHAsset 不是图片类型")
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isSynchronous = false
        options.progressHandler = { progress, _, _, _ in
            downloadProgress?(progress)
        }

        return try await request { complete in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if let error = Self.error(from: info) {
                    return complete(.failure(error))
                }
                guard let data else {
                    return complete(.failure(.iCloudDownloadFailed(underlying: nil)))
                }
                downloadProgress?(1)
                complete(.success(.data(data)))
            }
        }
    }

    // MARK: - 请求骨架

    /// 把 `PHImageManager` 的回调式请求桥接到 async，并接上任务取消。
    ///
    /// 视频和图片两条路径除了请求方法本身完全一致，统一走这里，
    /// 避免取消处理与 continuation 保护出现两份实现。
    private static func request<T>(
        _ body: @escaping (@escaping @Sendable (Result<T, WatermarkError>) -> Void) -> PHImageRequestID
    ) async throws -> T {
        let handle = RequestHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeGuard = ResumeGuard(continuation)
                handle.id = body { result in
                    switch result {
                    case .success(let value):   resumeGuard.succeed(value)
                    case .failure(let error):   resumeGuard.fail(error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    // MARK: - 错误映射

    private static func error(from info: [AnyHashable: Any]?) -> WatermarkError? {
        guard let info else { return nil }
        if (info[PHImageCancelledKey] as? Bool) == true {
            return .cancelled
        }
        if let error = info[PHImageErrorKey] as? Error {
            return .iCloudDownloadFailed(underlying: error)
        }
        return nil
    }

    /// 持有 `PHImageRequestID`，供任务取消时回收请求。
    private final class RequestHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var _id: PHImageRequestID = PHInvalidImageRequestID

        var id: PHImageRequestID {
            get { lock.withLock { _id } }
            set { lock.withLock { _id = newValue } }
        }

        func cancel() {
            let current = id
            guard current != PHInvalidImageRequestID else { return }
            PHImageManager.default().cancelImageRequest(current)
        }
    }

    /// Photos 的回调在某些情况下会触发多次（降级图、错误后重试），
    /// continuation 重复 resume 会直接崩溃，必须加一道闸。
    private final class ResumeGuard<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func succeed(_ value: T) {
            take()?.resume(returning: value)
        }

        func fail(_ error: WatermarkError) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<T, Error>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }
}
