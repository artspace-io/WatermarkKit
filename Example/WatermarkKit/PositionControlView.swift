//
//  PositionControlView.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import UIKit
import WatermarkKit

/// 位置调节面板：模式切换 + 九宫格 + 两条边距滑块。
///
/// 不用 delegate 协议，全部走闭包回调 —— 这个控件只服务于 Demo 的一个界面。
final class PositionControlView: UIView {

    var onModeChange: ((PlacementMode) -> Void)?
    var onPositionChange: ((WatermarkPosition) -> Void)?
    /// 参数依次是水平、垂直归一化边距。
    var onMarginChange: ((CGFloat, CGFloat) -> Void)?

    private let modeSegmented = UISegmentedControl(items: ["九宫格", "自由拖拽"])
    private let gridStack = UIStackView()
    private var gridButtons: [UIButton] = []
    private let horizontalSlider = UISlider()
    private let verticalSlider = UISlider()
    private let horizontalLabel = UILabel()
    private let verticalLabel = UILabel()
    private let hintLabel = UILabel()

    private enum Metric {
        /// 边距滑块上限，超过 25% 水印基本就挤到画面中间了，没有演示价值
        static let maxMargin: Float = 0.25
        static let gridSpacing: CGFloat = 6
        static let gridButtonSize: CGFloat = 34
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 同步

    /// 把整个面板同步到模型。
    ///
    /// 单向刷新而不是各控件自己维护状态 —— 模式、位置、禁用态之间联动太多，
    /// 分散维护迟早对不上（比如拖拽后九宫格忘了取消高亮）。
    func apply(_ settings: WatermarkSettings) {
        let enabled = settings.supportsPlacement
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1 : 0.4

        modeSegmented.selectedSegmentIndex = settings.mode.rawValue

        let highlighted = settings.mode == .grid ? settings.gridPosition : nil
        for (index, button) in gridButtons.enumerated() {
            let position = WatermarkPosition.allCases[index]
            let isOn = position == highlighted
            button.backgroundColor = isOn ? tintColor : .tertiarySystemFill
            button.layer.borderWidth = isOn ? 0 : 1
        }

        // 自由定位时库会忽略 margin，滑块置灰但保留数值，切回九宫格原样恢复
        let marginEnabled = settings.mode == .grid
        horizontalSlider.isEnabled = marginEnabled
        verticalSlider.isEnabled = marginEnabled
        horizontalSlider.alpha = marginEnabled ? 1 : 0.4
        verticalSlider.alpha = marginEnabled ? 1 : 0.4
        horizontalSlider.value = Float(settings.marginX)
        verticalSlider.value = Float(settings.marginY)
        horizontalLabel.text = marginLabel("水平边距", value: settings.marginX, enabled: marginEnabled)
        verticalLabel.text = marginLabel("垂直边距", value: settings.marginY, enabled: marginEnabled)

        hintLabel.text = settings.preset.placementHint
    }

    private func marginLabel(_ title: String, value: CGFloat, enabled: Bool) -> String {
        enabled ? "\(title) \(Int((value * 100).rounded()))%" : "\(title)（拖拽模式下不适用）"
    }

    // MARK: - 事件

    @objc
    private func modeChanged() {
        onModeChange?(PlacementMode(rawValue: modeSegmented.selectedSegmentIndex) ?? .grid)
    }

    @objc
    private func gridTapped(_ sender: UIButton) {
        guard WatermarkPosition.allCases.indices.contains(sender.tag) else { return }
        onPositionChange?(WatermarkPosition.allCases[sender.tag])
    }

    @objc
    private func marginChanged() {
        onMarginChange?(CGFloat(horizontalSlider.value), CGFloat(verticalSlider.value))
    }

    // MARK: - 布局

    private func setupSubviews() {
        modeSegmented.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        buildGrid()
        configure(horizontalSlider)
        configure(verticalSlider)
        configure(horizontalLabel)
        configure(verticalLabel)

        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            modeSegmented, gridStack, horizontalLabel, horizontalSlider,
            verticalLabel, verticalSlider, hintLabel
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: modeSegmented)
        stack.setCustomSpacing(14, after: gridStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// `WatermarkPosition.allCases` 恰好是行优先的 3×3 顺序，直接切三行即可。
    private func buildGrid() {
        gridStack.axis = .vertical
        gridStack.spacing = Metric.gridSpacing
        gridStack.alignment = .center

        for row in 0..<3 {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = Metric.gridSpacing

            for column in 0..<3 {
                let index = row * 3 + column
                let button = makeGridButton(index: index)
                gridButtons.append(button)
                rowStack.addArrangedSubview(button)
            }
            gridStack.addArrangedSubview(rowStack)
        }
    }

    private func makeGridButton(index: Int) -> UIButton {
        let button = UIButton(type: .custom)
        button.tag = index
        button.accessibilityLabel = WatermarkPosition.allCases[index].rawValue
        button.layer.cornerRadius = 6
        button.layer.borderColor = UIColor.separator.cgColor
        button.backgroundColor = .tertiarySystemFill
        button.addTarget(self, action: #selector(gridTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metric.gridButtonSize),
            button.heightAnchor.constraint(equalToConstant: Metric.gridButtonSize)
        ])
        return button
    }

    private func configure(_ slider: UISlider) {
        slider.minimumValue = 0
        slider.maximumValue = Metric.maxMargin
        slider.addTarget(self, action: #selector(marginChanged), for: .valueChanged)
    }

    private func configure(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
    }
}
