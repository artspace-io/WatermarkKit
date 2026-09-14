//
//  BackgroundExportGuard.swift
//  WatermarkKit
//

import AVFoundation
import UIKit

/// `AVAssetExportSession` 的 Sendable 包装。
///
/// 导出会话本身不是 `Sendable`，但进度轮询、后台守护、取消处理分散在不同的并发域，
/// 都需要拿到同一个会话。会话内部对这几个操作是线程安全的，因此装箱标注为 unchecked。
final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float { session.progress }

    func cancel() {
        session.cancelExport()
    }
}

/// 导出过程中的共享状态，供导出回调与后台守护跨线程读写。
final class ExportRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasInterruptedByBackground = false

    /// 取消是后台守护发起的，还是用户主动的 —— 两者走同一个回调，只能靠这个状态位区分。
    var wasInterruptedByBackground: Bool {
        get { lock.withLock { _wasInterruptedByBackground } }
        set { lock.withLock { _wasInterruptedByBackground = newValue } }
    }
}

/// App 切入后台时的导出守护。
///
/// 策略不是「一进后台就取消」—— 多数短视频在后台任务的宽限期内就能跑完，
/// 直接取消等于白白浪费已完成的工作。实际行为是：
///
/// 1. 切入后台 → 申请 `beginBackgroundTask`，让导出继续跑
/// 2. 后台时间即将耗尽 → 取消导出并标记为后台中断，由上层决定是否重跑
/// 3. `.failFast` 策略 → 切入后台立即取消
///
/// 渲染走的是 Core Image，进后台不会像 Core Animation 那样整个挂起，
/// 所以这里只需要管后台时长，不需要额外的进度停滞兜底。
@MainActor
final class BackgroundExportGuard {

    private let policy: BackgroundPolicy
    private let state: ExportRunState
    private let session: ExportSessionBox

    private var observers: [NSObjectProtocol] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(session: ExportSessionBox, state: ExportRunState, policy: BackgroundPolicy) {
        self.session = session
        self.state = state
        self.policy = policy
        observe()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // 通知已投递到主队列，但 MainActor.assumeIsolated 要 iOS 17，
                // 最低版本是 16，只能用 Task 跳一次主 actor。didEnterBackground 之后
                // 系统还留有数秒挂起宽限期，这一个 runloop tick 的延迟不影响申请后台任务。
                Task { @MainActor in self?.handleDidEnterBackground() }
            }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWillEnterForeground() }
            }
        )
    }

    private func handleDidEnterBackground() {
        guard policy == .suspendAndResume else {
            interrupt()
            return
        }
        // 争取后台执行时间，短视频往往能在宽限期内直接完成
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatermarkKit.Export") { [weak self] in
            Task { @MainActor in self?.interrupt() }
        }
    }

    private func handleWillEnterForeground() {
        endBackgroundTask()
    }

    /// 取消导出并标记为后台中断，与用户主动取消区分开。
    func interrupt() {
        state.wasInterruptedByBackground = true
        session.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        endBackgroundTask()
    }

    /// 等待 App 回到前台。已在前台时立即返回。
    static func waitForForeground() async {
        if UIApplication.shared.applicationState != .background { return }

        let holder = ObserverHolder()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            holder.token = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                holder.remove()
                continuation.resume()
            }
        }
    }

    /// 持有 observer token，避免在注册闭包里引用尚未初始化的自身。
    private final class ObserverHolder: @unchecked Sendable {
        var token: NSObjectProtocol?
        func remove() {
            guard let token else { return }
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
}
