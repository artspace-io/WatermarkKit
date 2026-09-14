//
//  WatermarkPreviewView.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import UIKit
import WatermarkKit

/// 预览控件：承载渲染结果，并把长按拖拽换算成归一化坐标。
final class WatermarkPreviewView: UIView {

    /// 拖拽回调，参数是归一化中心点（0...1，左上原点），语义与 `Anchor.relative` 一致。
    var onDragged: ((CGPoint) -> Void)?
    /// 拖拽开始回调，用来把界面切到自由定位模式。
    var onDragBegan: (() -> Void)?
    /// 拖拽结束回调，外部据此把夹过边界的位置同步回手柄。
    var onDragEnded: (() -> Void)?

    var isDragEnabled = true {
        didSet {
            longPress.isEnabled = isDragEnabled
            updateHandleVisibility()
        }
    }

    private let imageView = UIImageView()
    private let handleView = UIView()
    private let longPress = UILongPressGestureRecognizer()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    /// 手柄所在的归一化位置，nil 表示当前不是自由定位模式。
    private var handlePoint: CGPoint?

    private enum Metric {
        static let handleSize: CGFloat = 28
        static let cornerRadius: CGFloat = 12
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        repositionHandle()
    }

    // MARK: - 对外接口

    var image: UIImage? { imageView.image }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        // 渲染结果与底图尺寸一致，显示区不会跳变，但换素材时宽高比会变，手柄要重摆
        repositionHandle()
    }

    /// 摆放拖拽手柄；传 nil 隐藏（九宫格模式下不显示）。
    func setHandlePoint(_ point: CGPoint?) {
        handlePoint = point
        updateHandleVisibility()
        repositionHandle()
    }

    // MARK: - 坐标换算

    /// 图片在 `bounds` 内的实际绘制矩形。
    ///
    /// `contentMode == .scaleAspectFit` 时图片四周留黑边，直接拿 `bounds` 归一化会算错位置。
    private var displayedImageRect: CGRect {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// 触摸点 → 归一化坐标。
    private func normalizedPoint(from location: CGPoint) -> CGPoint {
        let rect = displayedImageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((location.x - rect.minX) / rect.width, 0), 1),
            y: min(max((location.y - rect.minY) / rect.height, 0), 1)
        )
    }

    /// 归一化坐标 → 视图坐标，用来摆手柄。
    private func viewPoint(from normalized: CGPoint) -> CGPoint {
        let rect = displayedImageRect
        return CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    // MARK: - 手势

    @objc
    private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        let normalized = normalizedPoint(from: location)

        switch recognizer.state {
        case .began:
            feedback.impactOccurred()
            onDragBegan?()
            track(normalized, at: location)

        case .changed:
            track(normalized, at: location)

        case .ended, .cancelled, .failed:
            handlePoint = normalized
            onDragged?(normalized)
            // 松手后由外部把夹过边界的位置回灌进来，这里不自作主张摆手柄
            onDragEnded?()

        default:
            break
        }
    }

    /// 手柄直接跟手，不等异步合成 —— 合成有几毫秒延迟，靠它跟手会发黏。
    private func track(_ normalized: CGPoint, at location: CGPoint) {
        handlePoint = normalized
        handleView.center = location
        onDragged?(normalized)
    }

    // MARK: - 布局

    private func setupSubviews() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = Metric.cornerRadius
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        handleView.isUserInteractionEnabled = false
        handleView.isHidden = true
        handleView.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        handleView.layer.borderColor = UIColor.white.cgColor
        handleView.layer.borderWidth = 2
        handleView.layer.cornerRadius = Metric.handleSize / 2
        handleView.layer.shadowColor = UIColor.black.cgColor
        handleView.layer.shadowOpacity = 0.4
        handleView.layer.shadowRadius = 3
        handleView.layer.shadowOffset = .zero
        handleView.bounds = CGRect(x: 0, y: 0, width: Metric.handleSize, height: Metric.handleSize)
        addSubview(handleView)

        longPress.minimumPressDuration = 0.15
        longPress.allowableMovement = 20
        longPress.addTarget(self, action: #selector(handleLongPress))
        addGestureRecognizer(longPress)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateHandleVisibility() {
        handleView.isHidden = handlePoint == nil || !isDragEnabled
    }

    private func repositionHandle() {
        guard let handlePoint else { return }
        handleView.center = viewPoint(from: handlePoint)
    }
}

/// 预览渲染器：同一时刻只跑一次合成，中间请求只保留最新一份。
///
/// 拖拽每帧都发一个 Task 会把渲染排成长队，松手后还在一路播放中间帧。
/// 这里用「跑一个 + 一个待办槽位」把中间值直接丢掉，节流由渲染耗时天然完成，不需要 timer。
@MainActor
final class PreviewRenderer {

    var onRendered: ((UIImage) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let logo: UIImage
    private var base: UIImage?
    private var pending: WatermarkSettings?
    private var isRunning = false

    init(logo: UIImage) {
        self.logo = logo
    }

    /// 底图，换素材时调用。
    func setBase(_ image: UIImage?) {
        base = image
        pending = nil
    }

    var canRender: Bool { base != nil }

    func request(_ settings: WatermarkSettings) {
        guard base != nil else { return }
        pending = settings                  // 旧的待办被直接覆盖，中间值就此丢弃
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    private func drain() async {
        defer { isRunning = false }

        while let settings = pending, let base = base {
            pending = nil
            // 预览走 .memoryOnly：渲染器对这个去向直接返回内存图、跳过整个编解码
            let config = settings.makeConfig(logo: logo, destination: .memoryOnly)
            do {
                let result = try await WatermarkKit.applyWatermark(to: .image(base), config: config)
                // 已经有更新的请求在排队，这张就是过时的，刷上去只会闪一下
                if pending == nil { onRendered?(result.image) }
            } catch {
                if pending == nil { onFailure?(error) }
            }
        }
    }
}
