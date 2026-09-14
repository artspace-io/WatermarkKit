//
//  WatermarkPosition.swift
//  WatermarkKit
//

import CoreGraphics

/// 九宫格预设位置。
///
/// 所有位置以「最终显示方向」为准 —— 视频侧已在布局阶段完成 `preferredTransform` 换算，
/// 业务方指定 `.bottomRight` 就是用户看到的右下角，无需关心底层坐标系。
public enum WatermarkPosition: String, Sendable, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case centerLeft
    case center
    case centerRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    /// 水平方向的对齐系数：0 = 贴左，0.5 = 居中，1 = 贴右。
    var horizontalBias: CGFloat {
        switch self {
        case .topLeft, .centerLeft, .bottomLeft:       return 0
        case .topCenter, .center, .bottomCenter:       return 0.5
        case .topRight, .centerRight, .bottomRight:    return 1
        }
    }

    /// 垂直方向的对齐系数（左上原点语义）：0 = 贴顶，0.5 = 居中，1 = 贴底。
    var verticalBias: CGFloat {
        switch self {
        case .topLeft, .topCenter, .topRight:             return 0
        case .centerLeft, .center, .centerRight:          return 0.5
        case .bottomLeft, .bottomCenter, .bottomRight:    return 1
        }
    }
}
