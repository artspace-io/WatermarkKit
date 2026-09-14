//
//  TemporaryFileManager.swift
//  WatermarkKit
//

import Foundation

/// Kit 管理的临时文件目录。
///
/// 视频文件动辄上百 MB，漏删会直接占用用户存储空间，所以所有权边界必须清楚：
/// - 处理失败或被取消 → Kit 负责清理半成品
/// - 处理成功 → 文件所有权移交调用方，Kit 不再主动删除
/// - 业务方可随时调用 `cleanupAll()` 兜底清理遗留文件
public final class TemporaryFileManager: @unchecked Sendable {

    public static let shared = TemporaryFileManager()

    private let lock = NSLock()
    private let fileManager = FileManager.default

    /// 所有临时产物的根目录，与系统临时目录下其他内容隔离。
    public var rootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WatermarkKit", isDirectory: true)
    }

    private init() {}

    /// 在独立的 UUID 子目录下生成一个输出路径。
    ///
    /// 每次处理独占一个子目录，取消时可以整个删掉而不影响并发进行的其他任务。
    func makeURL(fileExtension: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WatermarkError.outputPathNotWritable(directory, underlying: error)
        }
        return directory.appendingPathComponent("watermarked").appendingPathExtension(fileExtension)
    }

    /// 丢弃一个临时产物。
    ///
    /// 只清理 Kit 自己的目录，业务方通过 `.file(url)` 指定的路径一律不碰 ——
    /// 那是调用方的文件，删掉可能连带用户数据。
    func discard(_ url: URL?) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }

        let rootPath = rootDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { return }

        // 连同 UUID 子目录一起删，不留空壳；但绝不能误删根目录，那会波及并发进行的其他任务
        let directory = url.deletingLastPathComponent()
        let isTaskDirectory = directory.deletingLastPathComponent().standardizedFileURL.path == rootPath
        try? fileManager.removeItem(at: isTaskDirectory ? directory : url)
    }

    /// 清理全部遗留的临时文件。
    ///
    /// 建议业务方在合适时机（如 App 启动、处理队列清空后）调用一次兜底。
    /// 注意会删除此前处理成功、但调用方尚未搬走的文件。
    public func cleanupAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: rootDirectory)
    }

    /// 当前临时目录占用的字节数，供业务方决定是否需要清理。
    public func currentUsageBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
