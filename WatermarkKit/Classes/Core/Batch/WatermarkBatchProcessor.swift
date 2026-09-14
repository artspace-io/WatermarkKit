//
//  WatermarkBatchProcessor.swift
//  WatermarkKit
//

import AVFoundation
import ImageIO
import UIKit

/// 批量处理器。
///
/// 图片与视频采用完全不同的并发策略，不共用同一个上限：
///
/// - **视频串行（并发 1）**：视频编码走硬件编码器，是全局独占资源。并发多个
///   `AVAssetExportSession` 没有吞吐收益，反而互相抢占拖慢整体，4K 素材下还容易 OOM。
/// - **图片并发 `min(4, 核数)`**：瓶颈在内存峰值而非 CPU —— 每张解码后的位图可能
///   几十 MB，无节制并发会被 jetsam 直接杀掉。检测到大图时进一步降到 2。
public actor WatermarkBatchProcessor {

    /// 图片并发上限。取 4 而非核数，是因为限制因素是内存而不是算力。
    private static let maxImageConcurrency = 4
    /// 存在长边超过该值的大图时，并发进一步收紧。
    private static let largeImageThreshold: CGFloat = 4000
    private static let largeImageConcurrency = 2

    private let imageRenderer: any ImageWatermarkRendering
    private let videoRenderer: any VideoWatermarkRendering

    public init(
        imageRenderer: any ImageWatermarkRendering = ImageWatermarkRenderer(),
        videoRenderer: any VideoWatermarkRendering = VideoWatermarkRenderer()
    ) {
        self.imageRenderer = imageRenderer
        self.videoRenderer = videoRenderer
    }

    // MARK: - 图片

    /// 批量处理图片。
    ///
    /// 单项失败不会中断整批 —— 返回逐项的 `Result`，由业务方决定重试还是提示。
    /// 结果顺序与输入顺序严格一致。
    public func process(
        images sources: [ImageSource],
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil
    ) async -> [Result<ImageWatermarkResult, WatermarkError>] {
        guard !sources.isEmpty else { return [] }

        let concurrency = Self.imageConcurrency(for: sources)
        let renderer = imageRenderer
        var results = [Result<ImageWatermarkResult, WatermarkError>?](repeating: nil, count: sources.count)
        var completed = 0

        await withTaskGroup(of: (Int, Result<ImageWatermarkResult, WatermarkError>).self) { group in
            var next = 0

            // 先填满并发窗口
            while next < min(concurrency, sources.count) {
                let index = next
                let source = sources[index]
                group.addTask { await Self.render(source, at: index, config: config, renderer: renderer) }
                next += 1
            }

            // 每完成一个补一个，保证在途任务数恒定，而不是分批等最慢的那个
            while let (index, result) = await group.next() {
                results[index] = result
                completed += 1
                progress?.yield(Double(completed) / Double(sources.count))

                // 已取消时不再投放新任务，但仍要收完在途任务的结果
                guard !Task.isCancelled, next < sources.count else { continue }
                let pending = next
                let pendingSource = sources[pending]
                group.addTask { await Self.render(pendingSource, at: pending, config: config, renderer: renderer) }
                next += 1
            }
        }

        // 未被填充的位置只可能是整批取消时没排上队的任务
        return results.map { $0 ?? .failure(.cancelled) }
    }

    private static func render(
        _ source: ImageSource,
        at index: Int,
        config: WatermarkConfig,
        renderer: any ImageWatermarkRendering
    ) async -> (Int, Result<ImageWatermarkResult, WatermarkError>) {
        do {
            return (index, .success(try await renderer.applyWatermark(to: source, config: config)))
        } catch {
            return (index, .failure(error as? WatermarkError ?? .mapping(error)))
        }
    }

    // MARK: - 视频

    /// 批量处理视频，严格串行。
    ///
    /// 总进度 = 已完成数 / 总数 + 当前任务内部进度，因此进度条是连续的，
    /// 不会在任务切换时跳变。
    public func process(
        videos sources: [VideoSource],
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil
    ) async -> [Result<VideoWatermarkResult, WatermarkError>] {
        guard !sources.isEmpty else { return [] }

        var results: [Result<VideoWatermarkResult, WatermarkError>] = []
        results.reserveCapacity(sources.count)
        let total = Double(sources.count)

        for (index, source) in sources.enumerated() {
            if Task.isCancelled {
                results.append(contentsOf: Array(
                    repeating: Result<VideoWatermarkResult, WatermarkError>.failure(.cancelled),
                    count: sources.count - results.count
                ))
                break
            }

            let base = Double(index) / total
            var itemContinuation: AsyncStream<Double>.Continuation?
            let itemStream = AsyncStream<Double> { itemContinuation = $0 }

            let relay = Task {
                for await value in itemStream {
                    progress?.yield(base + value / total)
                }
            }

            do {
                let result = try await videoRenderer.applyWatermark(
                    to: source,
                    config: config,
                    progress: itemContinuation
                )
                results.append(.success(result))
            } catch {
                results.append(.failure(error as? WatermarkError ?? .mapping(error)))
            }

            itemContinuation?.finish()
            relay.cancel()
            progress?.yield(Double(index + 1) / total)
        }

        return results
    }

    // MARK: - 并发档位

    private static func imageConcurrency(for sources: [ImageSource]) -> Int {
        let hasLargeImage = sources.contains { pixelSize(of: $0).map(isLarge) ?? false }
        let ceiling = hasLargeImage ? largeImageConcurrency : maxImageConcurrency
        return max(1, min(ceiling, ProcessInfo.processInfo.activeProcessorCount))
    }

    private static func isLarge(_ size: CGSize) -> Bool {
        max(size.width, size.height) > largeImageThreshold
    }

    /// 读取图片像素尺寸。
    ///
    /// 文件与 Data 走 `CGImageSource` 只读属性，不做完整解码 ——
    /// 为了决定并发数而把每张图都解一遍，本身就会造成内存峰值。
    private static func pixelSize(of source: ImageSource) -> CGSize? {
        switch source {
        case .image(let image):
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        case .data(let data):
            return CGImageSourceCreateWithData(data as CFData, nil).flatMap(pixelSize(fromImageSource:))
        case .fileURL(let url):
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(pixelSize(fromImageSource:))
        }
    }

    private static func pixelSize(fromImageSource source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }
}
