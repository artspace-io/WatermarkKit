//
//  AppDelegate.swift
//  WatermarkKit
//
//  Created by Robin on 09/14/2026.
//  Copyright (c) 2026 Robin. All rights reserved.
//

import UIKit
import WatermarkKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 清理上次运行遗留的临时产物。视频文件体积大，不兜底清理会持续占用用户存储空间。
        WatermarkKit.cleanupTemporaryFiles()
        return true
    }
}
