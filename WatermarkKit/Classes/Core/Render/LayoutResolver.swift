//
//  LayoutResolver.swift
//  WatermarkKit
//

import CoreGraphics
import Foundation

/// 解析后的单个水印实例（平铺会展开成多个）。
struct ResolvedPlacement {
    let raster: WatermarkRasterizer.Raster
    /// 中心点，左上原点。
    let center: CGPoint
    let size: CGSize
    /// 绕自身中心的旋转弧度。
    let rotation: CGFloat
    let opacity: CGFloat
    let blendMode: CGBlendMode
}

/// 把归一化布局解析成具体画布上的像素位置。
enum LayoutResolver {

    static func resolve(
        config: WatermarkConfig,
        canvasSize: CGSize
    ) throws -> [ResolvedPlacement] {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw WatermarkError.invalidConfiguration("画布尺寸非法：\(canvasSize)")
        }
        guard !config.items.isEmpty else {
            throw WatermarkError.invalidConfiguration("未提供任何水印条目")
        }

        return try config.orderedItems.flatMap { item in
            try resolve(item: item, canvasSize: canvasSize)
        }
    }

    private static func resolve(
        item: WatermarkItem,
        canvasSize: CGSize
    ) throws -> [ResolvedPlacement] {
        let intrinsic = try WatermarkRasterizer.intrinsicSize(of: item.content, canvasSize: canvasSize)
        let target = item.layout.sizing.resolve(intrinsicSize: intrinsic, canvasSize: canvasSize)
        guard target.width > 0, target.height > 0 else {
            throw WatermarkError.invalidConfiguration("水印目标尺寸为 0，请检查 sizing 取值")
        }

        let raster = try WatermarkRasterizer.rasterize(
            item.content,
            targetSize: target,
            canvasSize: canvasSize
        )
        let rotation = item.layout.rotation
        let anchorCenter = anchorCenter(
            layout: item.layout,
            watermarkSize: raster.size,
            rotation: rotation,
            canvasSize: canvasSize
        )

        let centers: [CGPoint]
        if let tiling = item.layout.tiling {
            centers = tilePositions(
                tiling: tiling,
                tileSize: raster.size,
                canvasSize: canvasSize
            )
        } else {
            centers = [anchorCenter]
        }

        return centers.map { center in
            ResolvedPlacement(
                raster: raster,
                center: center,
                size: raster.size,
                rotation: rotation,
                opacity: min(max(item.style.opacity, 0), 1),
                blendMode: item.style.blendMode
            )
        }
    }

    // MARK: - 定位

    private static func anchorCenter(
        layout: WatermarkLayout,
        watermarkSize: CGSize,
        rotation: CGFloat,
        canvasSize: CGSize
    ) -> CGPoint {
        switch layout.anchor {
        case .relative(let point):
            return CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)

        case .preset(let position):
            let insets = layout.margin.resolved(in: canvasSize)
            let available = CGRect(
                x: insets.left,
                y: insets.top,
                width: max(canvasSize.width - insets.left - insets.right, 0),
                height: max(canvasSize.height - insets.top - insets.bottom, 0)
            )
            // 用旋转后的外接矩形做边界约束，否则倾斜的角标会被画布边缘裁掉
            let bounding = boundingSize(of: watermarkSize, rotation: rotation)
            let freeWidth = max(available.width - bounding.width, 0)
            let freeHeight = max(available.height - bounding.height, 0)
            return CGPoint(
                x: available.minX + bounding.width / 2 + freeWidth * position.horizontalBias,
                y: available.minY + bounding.height / 2 + freeHeight * position.verticalBias
            )
        }
    }

    /// 尺寸经旋转后的轴对齐外接矩形。
    static func boundingSize(of size: CGSize, rotation: CGFloat) -> CGSize {
        guard rotation != 0 else { return size }
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        return CGSize(
            width: size.width * cosine + size.height * sine,
            height: size.width * sine + size.height * cosine
        )
    }

    // MARK: - 平铺

    /// 以画布中心为原点铺满整个画面。
    ///
    /// 数量超过 `maxTileCount` 时等比放大间距重算，而不是截断 ——
    /// 截断会让画面一半有水印一半没有，放大间距只是密度降低，视觉仍然完整。
    private static func tilePositions(
        tiling: WatermarkTiling,
        tileSize: CGSize,
        canvasSize: CGSize
    ) -> [CGPoint] {
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // 覆盖半径取画布对角线的一半再加一个水印，保证旋转后四角也被铺到
        let radius = hypot(canvasSize.width, canvasSize.height) / 2
            + max(tileSize.width, tileSize.height)

        var stepX = max(tiling.spacing.width * canvasSize.width, 1)
        var stepY = max(tiling.spacing.height * canvasSize.height, 1)

        // 最多收敛 4 轮，避免间距极小时陷入长循环
        for _ in 0..<4 {
            let columns = Int(ceil(radius / stepX))
            let rows = Int(ceil(radius / stepY))
            let estimated = (columns * 2 + 1) * (rows * 2 + 1)
            guard estimated > tiling.maxTileCount else { break }
            let factor = (Double(estimated) / Double(tiling.maxTileCount)).squareRoot()
            stepX *= CGFloat(factor)
            stepY *= CGFloat(factor)
        }

        let columns = Int(ceil(radius / stepX))
        let rows = Int(ceil(radius / stepY))
        let cosine = cos(tiling.angle)
        let sine = sin(tiling.angle)
        let bounding = boundingSize(of: tileSize, rotation: tiling.angle)

        var positions: [CGPoint] = []
        positions.reserveCapacity(min((columns * 2 + 1) * (rows * 2 + 1), tiling.maxTileCount))

        for row in -rows...rows {
            let stagger = tiling.isStaggered && row % 2 != 0 ? stepX / 2 : 0
            for column in -columns...columns {
                let localX = CGFloat(column) * stepX + stagger
                let localY = CGFloat(row) * stepY
                let point = CGPoint(
                    x: canvasCenter.x + localX * cosine - localY * sine,
                    y: canvasCenter.y + localX * sine + localY * cosine
                )
                // 剔除完全落在画布外的实例，减少无效绘制
                guard point.x + bounding.width / 2 > 0,
                      point.x - bounding.width / 2 < canvasSize.width,
                      point.y + bounding.height / 2 > 0,
                      point.y - bounding.height / 2 < canvasSize.height else { continue }
                positions.append(point)
                if positions.count >= tiling.maxTileCount { return positions }
            }
        }
        return positions
    }
}
