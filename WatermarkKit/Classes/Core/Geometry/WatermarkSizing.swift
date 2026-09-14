//
//  WatermarkSizing.swift
//  WatermarkKit
//

import CoreGraphics

/// 水印尺寸表达方式，一律相对画布，不接受像素值。
public enum WatermarkSizing: Sendable, Equatable {
    /// 水印宽度 = 画布宽度 × value，高度按内容宽高比推导。
    case relativeWidth(CGFloat)
    /// 水印高度 = 画布高度 × value，宽度按内容宽高比推导。
    case relativeHeight(CGFloat)
    /// 以画布短边为基准缩放，横竖屏下水印视觉大小最接近，推荐用于九宫格角标。
    case relativeShorterEdge(CGFloat)
    /// 按内容固有尺寸（文字按字号排版结果，图片按 point 尺寸）不做缩放。
    case intrinsic

    /// 依据内容固有尺寸与画布尺寸求出目标绘制尺寸，始终保持内容宽高比。
    func resolve(intrinsicSize: CGSize, canvasSize: CGSize) -> CGSize {
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else { return .zero }
        let aspect = intrinsicSize.width / intrinsicSize.height

        switch self {
        case .relativeWidth(let ratio):
            let width = canvasSize.width * max(0, ratio)
            return CGSize(width: width, height: width / aspect)
        case .relativeHeight(let ratio):
            let height = canvasSize.height * max(0, ratio)
            return CGSize(width: height * aspect, height: height)
        case .relativeShorterEdge(let ratio):
            let base = min(canvasSize.width, canvasSize.height) * max(0, ratio)
            // 以短边为基准时，按内容较长的一边贴合 base，避免极端宽高比撑爆画布
            return aspect >= 1
                ? CGSize(width: base, height: base / aspect)
                : CGSize(width: base * aspect, height: base)
        case .intrinsic:
            return intrinsicSize
        }
    }
}
