//
//  ViewController.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import AVKit
import UIKit
import WatermarkKit

/// WatermarkKit 用法演示。
///
/// 相册素材经 `PHPickerViewController` 拷贝成本地文件后处理，全程不需要相册权限；
/// 需要演示 `WatermarkKit/Photos` 那条 `PHAsset` 路径时才用得上 Info.plist 里的
/// `NSPhotoLibraryUsageDescription`（已经配好了）。
final class ViewController: UIViewController {

    private let previewView = WatermarkPreviewView()
    private let positionControl = PositionControlView()
    private let presetSegmented = UISegmentedControl(items: WatermarkPreset.allCases.map(\.title))
    private let pickButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()

    private let logo = SampleAssets.logo()
    private lazy var renderer = PreviewRenderer(logo: logo)
    private let mediaPicker = MediaPicker()

    private var settings = WatermarkSettings()
    private var media = SampleAssets.item()
    /// 导出产物，分享与播放都指向它；任何参数改动都会把它作废。
    private var exportedURL: URL?
    private var isExporting = false

    private var currentTask: Task<Void, Never>?
    private var videoTask: Task<VideoWatermarkResult, Error>?
    /// 导出代次，`cancelWork()` 递增；异步收尾据此判断自己是否已被作废。
    private var exportGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WatermarkKit"
        view.backgroundColor = .systemBackground
        setupUI()
        bindCallbacks()
        adopt(media)
    }

    deinit {
        currentTask?.cancel()
        videoTask?.cancel()
    }

    // MARK: - 状态同步

    /// 所有界面状态从 `settings` / `media` / `isExporting` 单向推导。
    ///
    /// 模式、位置、禁用态之间联动太多，分散在各个回调里维护迟早会对不上
    /// （典型的是拖拽之后九宫格忘了取消高亮）。
    private func refreshControls() {
        positionControl.apply(settings)
        if isExporting { positionControl.isUserInteractionEnabled = false }

        let canDrag = settings.supportsPlacement && !isExporting
        previewView.isDragEnabled = canDrag
        let showsHandle = settings.supportsPlacement && settings.mode == .free
        previewView.setHandlePoint(showsHandle ? settings.freePoint : nil)

        pickButton.isEnabled = !isExporting
        presetSegmented.isEnabled = !isExporting
        exportButton.isEnabled = !isExporting
        playButton.isHidden = !(media.isVideo && exportedURL != nil)
        playButton.isEnabled = !isExporting
        shareButton.isEnabled = exportedURL != nil && !isExporting
    }

    /// 参数一变，上一次的导出产物就过期了。
    private func invalidateResult() {
        exportedURL = nil
    }

    private func settingsChanged() {
        clampFreePoint()
        invalidateResult()
        refreshControls()
        renderer.request(settings)
    }

    /// 换预设或换素材都会改变水印的外接尺寸与画布比例，自由定位的落点要重新夹一次，
    /// 否则切过去的那一下水印可能已经探出画布了。
    private func clampFreePoint() {
        guard settings.mode == .free else { return }
        settings.freePoint = settings.clampedCenter(
            settings.freePoint,
            canvasSize: media.previewBase.size
        )
    }

    // MARK: - 素材

    @objc
    private func pickMedia() {
        mediaPicker.present(from: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let item):
                self.adopt(item)
            case .failure(let error):
                self.statusLabel.text = "载入失败：\(error.localizedDescription)"
            }
        }
    }

    private func adopt(_ item: MediaItem) {
        cancelWork()

        // 换素材时把上一份拷贝删掉，视频文件体积大，攒着会一直占用存储
        if let previous = media.sourceURL, previous != item.sourceURL {
            try? FileManager.default.removeItem(at: previous)
        }

        media = item
        previewView.setImage(item.previewBase)
        renderer.setBase(item.previewBase)
        statusLabel.text = item.summary
        settingsChanged()
    }

    // MARK: - 导出

    @objc
    private func save() {
        guard !isExporting else { return }
        cancelWork()
        invalidateResult()

        let config = settings.makeConfig(logo: logo, destination: .temporary)

        if let videoSource = media.videoSource {
            exportVideo(videoSource, config: config)
        } else if let imageSource = media.imageSource {
            exportImage(imageSource, config: config)
        } else {
            statusLabel.text = "没有可导出的素材"
        }
    }

    private func exportImage(_ source: ImageSource, config: WatermarkConfig) {
        let generation = beginExport(status: "处理中…")

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.endExport(generation) }
            do {
                let result = try await WatermarkKit.applyWatermark(to: source, config: config)
                guard generation == self.exportGeneration else { return }
                self.previewView.setImage(result.image)
                self.exportedURL = result.fileURL
                self.statusLabel.text = Self.describe(result)
            } catch {
                self.reportFailure(error, generation: generation)
            }
        }
    }

    private func exportVideo(_ source: VideoSource, config: WatermarkConfig) {
        let generation = beginExport(status: "导出中…")
        progressView.isHidden = false
        progressView.progress = 0

        let (stream, task) = WatermarkKit.videoRenderer.watermarkWithProgress(source, config: config)
        videoTask = task

        currentTask = Task { [weak self] in
            guard let self else { return }
            let progressTask = Task { @MainActor [weak self] in
                for await value in stream {
                    guard let self, generation == self.exportGeneration else { return }
                    self.progressView.progress = Float(value)
                }
            }
            defer {
                progressTask.cancel()
                self.endExport(generation)
            }

            do {
                let result = try await task.value
                guard generation == self.exportGeneration else { return }
                self.exportedURL = result.fileURL
                self.statusLabel.text = Self.describe(result)
            } catch {
                self.reportFailure(error, generation: generation)
            }
        }
    }

    /// 进入导出态并领一个代次号。
    ///
    /// 代次号用来判定「我还是不是当前那一次导出」：`cancelWork()` 之后紧接着可能就开了新一轮，
    /// 旧任务的收尾要是照常跑，会把新一轮的进行中状态直接抹掉。
    private func beginExport(status: String) -> Int {
        statusLabel.text = status
        setExporting(true)
        return exportGeneration
    }

    private func endExport(_ generation: Int) {
        guard generation == exportGeneration else { return }
        progressView.isHidden = true
        setExporting(false)
    }

    private func reportFailure(_ error: Error, generation: Int) {
        guard generation == exportGeneration else { return }
        if error is CancellationError || (error as? WatermarkError)?.isCancellation == true {
            statusLabel.text = "已取消"
        } else {
            statusLabel.text = "失败：\(error.localizedDescription)"
        }
    }

    private func setExporting(_ value: Bool) {
        isExporting = value
        refreshControls()
    }

    private func cancelWork() {
        exportGeneration &+= 1
        currentTask?.cancel()
        videoTask?.cancel()
        currentTask = nil
        videoTask = nil
        progressView.isHidden = true
        setExporting(false)
    }

    // MARK: - 结果

    @objc
    private func share() {
        guard let exportedURL else { return }
        // 产物在 Kit 的临时目录里，可能已被 cleanupTemporaryFiles() 清掉。
        // 不先确认就弹面板，用户看到的是一个读不出内容的分享页（控制台只有 error fetching item）
        guard FileManager.default.fileExists(atPath: exportedURL.path) else {
            invalidateResult()
            refreshControls()
            statusLabel.text = "导出产物已不存在，请重新导出"
            return
        }

        // 分享文件 URL 而不是 UIImage：后者会被系统重新编码，写进去的 EXIF 全丢
        let activity = UIActivityViewController(activityItems: [exportedURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        activity.popoverPresentationController?.sourceRect = shareButton.bounds
        present(activity, animated: true)
    }

    @objc
    private func play() {
        guard let exportedURL, media.isVideo else { return }
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: exportedURL)
        present(controller, animated: true) { controller.player?.play() }
    }

    private static func describe(_ result: ImageWatermarkResult) -> String {
        let size = result.image.size
        var parts = [
            "图片完成 \(Int(size.width))×\(Int(size.height))",
            formatName(result.actualFormat),
            result.metadataPreserved ? "EXIF 已保留" : "EXIF 未保留"
        ]
        if result.didFallbackFromHEIC { parts.append("HEIC 不支持已降级") }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ result: VideoWatermarkResult) -> String {
        var parts = [
            "导出完成 \(Int(result.renderSize.width))×\(Int(result.renderSize.height))",
            "预设 \(result.appliedPreset.replacingOccurrences(of: "AVAssetExportPreset", with: ""))"
        ]
        if result.didDowngradeHDR { parts.append("HDR 已降级 SDR") }
        if result.didSkipWatermark { parts.append("已跳过水印") }
        if result.backgroundRestartCount > 0 { parts.append("后台重跑 \(result.backgroundRestartCount) 次") }
        return parts.joined(separator: " · ")
    }

    private static func formatName(_ format: WatermarkImageFormat) -> String {
        switch format {
        case .jpeg:     return "JPEG"
        case .png:      return "PNG"
        case .heic:     return "HEIC"
        }
    }
}

// MARK: - 回调接线

private extension ViewController {

    func bindCallbacks() {
        renderer.onRendered = { [weak self] image in
            self?.previewView.setImage(image)
        }
        renderer.onFailure = { [weak self] error in
            self?.statusLabel.text = "预览失败：\(error.localizedDescription)"
        }

        previewView.onDragBegan = { [weak self] in
            guard let self else { return }
            self.settings.mode = .free
            self.invalidateResult()
            self.refreshControls()
        }
        previewView.onDragged = { [weak self] point in
            guard let self else { return }
            self.settings.freePoint = self.settings.clampedCenter(
                point,
                canvasSize: self.media.previewBase.size
            )
            self.renderer.request(self.settings)
        }
        previewView.onDragEnded = { [weak self] in
            // 把夹过边界的位置同步回手柄，手柄与水印才对得上
            self?.refreshControls()
        }

        positionControl.onModeChange = { [weak self] mode in
            self?.settings.mode = mode
            self?.settingsChanged()
        }
        positionControl.onPositionChange = { [weak self] position in
            guard let self else { return }
            // 点九宫格即视为回到预设模式，省得用户还要先去切分段控件
            self.settings.mode = .grid
            self.settings.gridPosition = position
            self.settingsChanged()
        }
        positionControl.onMarginChange = { [weak self] horizontal, vertical in
            guard let self else { return }
            self.settings.marginX = horizontal
            self.settings.marginY = vertical
            self.settingsChanged()
        }
    }

    @objc
    func presetChanged() {
        settings.preset = WatermarkPreset(rawValue: presetSegmented.selectedSegmentIndex) ?? .logo
        settingsChanged()
    }
}

// MARK: - 界面搭建

private extension ViewController {

    func setupUI() {
        presetSegmented.selectedSegmentIndex = 0
        presetSegmented.addTarget(self, action: #selector(presetChanged), for: .valueChanged)

        configure(pickButton, title: "从相册选择照片或视频", style: .tinted, action: #selector(pickMedia))
        configure(exportButton, title: "导出", style: .filled, action: #selector(save))
        configure(playButton, title: "播放", style: .gray, action: #selector(play))
        configure(shareButton, title: "分享", style: .gray, action: #selector(share))

        progressView.isHidden = true
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        let actionStack = UIStackView(arrangedSubviews: [exportButton, playButton, shareButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 12
        actionStack.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            pickButton, presetSegmented, previewView, positionControl,
            progressView, statusLabel, actionStack
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 控制面板在小屏上放不下，整体塞进滚动视图
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.addSubview(stack)
        view.addSubview(scrollView)

        let guide = view.safeAreaLayoutGuide
        let content = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),

            previewView.heightAnchor.constraint(equalToConstant: 300)
        ])
    }

    private enum ButtonStyle {
        case filled
        case tinted
        case gray
    }

    private func configure(_ button: UIButton, title: String, style: ButtonStyle, action: Selector) {
        var configuration: UIButton.Configuration
        switch style {
        case .filled:   configuration = .filled()
        case .tinted:   configuration = .tinted()
        case .gray:     configuration = .gray()
        }
        configuration.title = title
        configuration.buttonSize = .medium
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }
}
