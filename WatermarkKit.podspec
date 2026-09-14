#
# Be sure to run `pod lib lint WatermarkKit.podspec' to ensure this is a
# valid spec before submitting.
#

Pod::Spec.new do |s|
  s.name             = 'WatermarkKit'
  s.version          = '0.1.0'
  s.summary          = '图片与视频水印工具库，支持文字/图片水印、九宫格布局、平铺与批量处理。'

  s.description      = <<-DESC
WatermarkKit 是一个同时覆盖「相册图片/视频加水印」与「AI 生成内容自动加水印」两类场景的
Swift 工具库。

- 文字与图片水印，支持描边、阴影、旋转、平铺与多水印叠加
- 几何量全部归一化，同一份配置在任意分辨率下视觉一致
- 视频走 AVMutableVideoComposition + CALayer 系统级合成，长视频无内存爆炸风险
- 正确处理 preferredTransform，横竖屏与前置摄像头镜像素材方位无误
- 图片输出经 CGImageDestination 保留 EXIF 元数据，GPS 单独开关
- 核心 async/await，附带 Combine 与 completion handler 便利层
                       DESC

  s.homepage         = 'https://github.com/artspace-io/WatermarkKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Robin' => 'enamourchen@outlook.com' }
  s.source           = { :git => 'https://github.com/artspace-io/WatermarkKit.git', :tag => s.version.to_s }

  # async/await 与 Combine 最低 iOS 13，但 AVAsset.load(_:) 等 async 属性加载 API 自 iOS 16 起提供，
  # 低于 16 只能使用已废弃的同步属性访问，在严格并发下无干净写法。
  s.ios.deployment_target = '16.0'
  s.swift_versions = ['5.9']

  s.default_subspec = 'Core'

  # 核心能力，不含任何 Photos 符号 —— 纯 AI 生成场景无需声明相册权限
  s.subspec 'Core' do |core|
    core.source_files = 'WatermarkKit/Classes/Core/**/*.swift'
    core.frameworks = 'UIKit', 'AVFoundation', 'CoreMedia', 'CoreImage',
                      'CoreGraphics', 'ImageIO', 'UniformTypeIdentifiers', 'Combine'
  end

  # 相册场景：PHAsset 输入与 iCloud 资源下载
  s.subspec 'Photos' do |photos|
    photos.source_files = 'WatermarkKit/Classes/Photos/**/*.swift'
    photos.dependency 'WatermarkKit/Core'
    photos.frameworks = 'Photos'
  end
end
