# WatermarkKit

[![License](https://img.shields.io/cocoapods/l/WatermarkKit.svg?style=flat)](https://cocoapods.org/pods/WatermarkKit)
[![Platform](https://img.shields.io/cocoapods/p/WatermarkKit.svg?style=flat)](https://cocoapods.org/pods/WatermarkKit)

图片与视频水印工具库，同时覆盖「相册素材加水印」与「AI 生成内容自动加水印」两类场景。

## 特性

- 文字与图片水印，支持描边、阴影、旋转、平铺、多水印叠加
- **几何量全部归一化**，同一份配置在 720p 与 4K 上视觉一致，不写死任何像素值
- 视频走 `AVMutableVideoComposition` + Core Image 系统级合成，长视频无内存爆炸风险
- 正确处理 `preferredTransform`，横竖屏与前置摄像头镜像素材方位无误
- 图片经 `CGImageDestination` 保留 EXIF，GPS 单独开关（默认剥离）
- 核心 `async/await`，附带 Combine 与 completion handler 便利层
- 批量处理：视频串行、图片按内存压力限流

## 安装

```ruby
pod 'WatermarkKit'              # 核心能力
pod 'WatermarkKit/Photos'       # 需要 PHAsset 输入时再加这个
```

最低支持 **iOS 16.0**。

`WatermarkKit/Photos` 是独立 subspec：不处理相册素材的项目无需引入，
也就不必在 Info.plist 里声明相册权限。

## 快速开始

### 图片

```swift
import WatermarkKit

let config = WatermarkConfig.bottomRightLogo(logoImage)
let result = try await WatermarkKit.applyWatermark(to: .image(photo), config: config)
imageView.image = result.image
```

需要保留拍摄日期时，传文件或原始数据而不是 `UIImage` ——
`UIImage` 在解码那一刻就把 EXIF 丢了：

```swift
var config = WatermarkConfig.bottomRightLogo(logoImage)
config.output = OutputConfig(
    imageFormat: .heic(quality: 0.9),   // 设备不支持时自动降级 JPEG
    preservesMetadata: true,            // 保留 EXIF / 拍摄时间
    preservesLocation: false,           // GPS 默认剥离
    destination: .temporary
)

let result = try await WatermarkKit.applyWatermark(to: .fileURL(photoURL), config: config)
print(result.fileURL!, result.actualFormat, result.metadataPreserved)
```

### 视频

```swift
let (progressStream, task) = WatermarkKit.videoRenderer
    .watermarkWithProgress(.url(videoURL), config: config)

Task {
    for await value in progressStream {
        progressView.progress = Float(value)
    }
}

let result = try await task.value
print(result.fileURL, result.renderSize)
if result.didDowngradeHDR { print("HDR 已降级为 SDR") }
```

取消直接取消 `Task`，Kit 会清掉半成品文件：

```swift
task.cancel()
```

### 相册（需 `WatermarkKit/Photos`）

```swift
import WatermarkKit

// 自动处理 iCloud 下载，进度已合并：下载 0~0.3，导出 0.3~1
let result = try await WatermarkKit.videoRenderer.applyWatermark(
    to: phAsset,
    config: config,
    progress: continuation
)
```

### 批量

```swift
let processor = WatermarkBatchProcessor()

// 视频严格串行 —— 硬件编码器是独占资源，并发只会互相拖慢
let results = await processor.process(videos: sources, config: config)

for case .failure(let error) in results {
    print("失败：\(error.localizedDescription)")   // 单项失败不中断整批
}
```

## 自定义水印

```swift
let config = WatermarkConfig(items: [
    // 满屏斜向平铺的防盗用文字
    WatermarkItem(
        content: .text("内部资料", attributes: TextAttributes(
            font: .systemFont(ofSize: 48, weight: .bold),
            color: .white,
            strokeColor: .black,
            strokeWidth: -2
        )),
        layout: WatermarkLayout(
            sizing: .relativeWidth(0.2),
            rotation: -.pi / 9,
            tiling: WatermarkTiling(maxTileCount: 200),
            zIndex: 0
        ),
        style: WatermarkStyle(opacity: 0.15)
    ),
    // 压在最上层的角标
    WatermarkItem(
        content: .image(logo),
        layout: WatermarkLayout(
            anchor: .preset(.bottomRight),
            margin: .all(0.04),
            sizing: .relativeShorterEdge(0.18),
            zIndex: 1
        )
    )
])
```

几何约定：

| 概念 | 取值 | 说明 |
| --- | --- | --- |
| `margin` | 0...1 | 相对画布宽/高的比例 |
| `sizing` | 0...1 | `.relativeWidth` / `.relativeHeight` / `.relativeShorterEdge` |
| `anchor` | 九宫格或 0...1 坐标 | `.relative` 给的是水印中心点 |
| `rotation` | 弧度 | 绕水印自身中心 |
| `zIndex` | Int | 值大的压在上面 |

位置一律以**用户看到的方向**为准：`.bottomRight` 在图片和视频上都落在右下角，
视频侧的 `preferredTransform` 换算由 Kit 内部处理。

## 临时文件

输出到 `.temporary` 时文件写在 Kit 管理的临时目录下：

- 失败 / 取消 → Kit 自动清理
- 成功 → 所有权移交调用方，Kit 不再主动删除

建议在 App 启动时兜底清理一次：

```swift
WatermarkKit.cleanupTemporaryFiles()
```

## 已知限制

| 限制 | 说明 |
| --- | --- |
| 无法逐帧改变水印内容 | 水印预先合成成一张叠加图后逐帧复用，随播放递增的时间码需要逐帧渲染管线 |
| 不能用于实时预览 | 该合成方案仅用于离线导出，播放器预览请另叠加原生 `UIView` |
| 后台「续跑」实为重跑 | `AVAssetExportSession` 没有暂停恢复能力，长视频切后台回来会看到进度回退 |
| HDR 降级 SDR | 经 animationTool 合成的 HDR 素材会被 tone-map，可通过 `hdrPolicy` 改为跳过水印 |
| 不支持精确码率 | 导出走预设驱动，精确码率需要 `AVAssetWriter` 通道 |
| `.medium` / `.low` 会缩分辨率 | 这两个档位的质量与输出尺寸由系统决定，实测竖屏 1320×2868 走 `MediumQuality` 被压到 220×480；`.highest` 严格等于源分辨率，编码器不可用时报错而非静默缩小 |
| Live Photo | 降级为静态图输出 |

详见 [需求文档](doc/水印工具类需求文档.md) 的「非目标」章节。

## Example

```bash
cd Example
pod install
open WatermarkKit.xcworkspace
```

## License

WatermarkKit is available under the MIT license. See the LICENSE file for more info.
