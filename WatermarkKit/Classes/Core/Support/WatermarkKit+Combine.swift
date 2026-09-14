//
//  WatermarkKit+Combine.swift
//  WatermarkKit
//

import Combine
import Foundation

/// Combine 与 completion handler 便利层。
///
/// 核心实现始终是 `async throws`，这一层只做包装，供尚未迁移到并发模型的
/// UIKit / Combine 代码调用，不含任何独立的处理逻辑。
public extension ImageWatermarkRendering {

    func watermarkPublisher(
        for source: ImageSource,
        config: WatermarkConfig
    ) -> AnyPublisher<ImageWatermarkResult, WatermarkError> {
        AsyncTaskPublisher {
            try await applyWatermark(to: source, config: config)
        }
        .eraseToAnyPublisher()
    }

    /// completion handler 版本，返回的 `Task` 可用于取消。
    @discardableResult
    func applyWatermark(
        to source: ImageSource,
        config: WatermarkConfig,
        completion: @escaping @Sendable (Result<ImageWatermarkResult, WatermarkError>) -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                completion(.success(try await applyWatermark(to: source, config: config)))
            } catch {
                completion(.failure(error as? WatermarkError ?? .mapping(error)))
            }
        }
    }
}

public extension VideoWatermarkRendering {

    /// 视频处理的 Combine 版本。
    ///
    /// 进度通过单独的 `AsyncStream` 暴露而非并入 `Publisher` 事件流 ——
    /// 把进度和最终结果混在同一个 `Output` 里会迫使订阅方对每个事件做分支判断。
    func watermarkPublisher(
        for source: VideoSource,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil
    ) -> AnyPublisher<VideoWatermarkResult, WatermarkError> {
        AsyncTaskPublisher {
            try await applyWatermark(to: source, config: config, progress: progress)
        }
        .eraseToAnyPublisher()
    }

    @discardableResult
    func applyWatermark(
        to source: VideoSource,
        config: WatermarkConfig,
        progress: AsyncStream<Double>.Continuation? = nil,
        completion: @escaping @Sendable (Result<VideoWatermarkResult, WatermarkError>) -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                completion(.success(try await applyWatermark(to: source, config: config, progress: progress)))
            } catch {
                completion(.failure(error as? WatermarkError ?? .mapping(error)))
            }
        }
    }
}

/// 把一次 async 调用包装成 Combine `Publisher`，订阅被取消时同步取消底层 `Task`。
struct AsyncTaskPublisher<Output: Sendable>: Publisher {
    typealias Failure = WatermarkError

    private let operation: @Sendable () async throws -> Output

    init(_ operation: @escaping @Sendable () async throws -> Output) {
        self.operation = operation
    }

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == WatermarkError {
        subscriber.receive(subscription: Subscription(operation: operation, subscriber: subscriber))
    }

    private final class Subscription<S: Subscriber>: Combine.Subscription, @unchecked Sendable
    where S.Input == Output, S.Failure == WatermarkError {

        private let operation: @Sendable () async throws -> Output
        private var subscriber: S?
        private var task: Task<Void, Never>?
        private let lock = NSLock()

        init(operation: @escaping @Sendable () async throws -> Output, subscriber: S) {
            self.operation = operation
            self.subscriber = subscriber
        }

        func request(_ demand: Subscribers.Demand) {
            guard demand > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard task == nil else { return }        // 只执行一次，后续 demand 不重复触发

            task = Task { [operation] in
                do {
                    let value = try await operation()
                    self.finish { subscriber in
                        _ = subscriber.receive(value)
                        subscriber.receive(completion: .finished)
                    }
                } catch {
                    let failure = error as? WatermarkError ?? .mapping(error)
                    self.finish { subscriber in
                        subscriber.receive(completion: .failure(failure))
                    }
                }
            }
        }

        func cancel() {
            lock.lock()
            let running = task
            task = nil
            subscriber = nil
            lock.unlock()
            running?.cancel()
        }

        private func finish(_ body: (S) -> Void) {
            lock.lock()
            let target = subscriber
            subscriber = nil
            lock.unlock()
            guard let target else { return }
            body(target)
        }
    }
}
