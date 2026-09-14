//
//  Tests.swift
//  WatermarkKit_Tests
//

// swiftlint:disable file_length

import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import WatermarkKit

// MARK: - preferredTransform 换算

/// 方向换算是整套方案最主要的 bug 来源，这里逐个角度加镜像素材做覆盖。
///
/// 变换本身现在由 `applyingCIFiltersWithHandler` 依据轨道的 `preferredTransform` 施加，
/// 库里只算「画面最终多大」——那是水印布局的画布，算错水印就会落到画外。
final class OrientationTests: XCTestCase {

    private let landscape = CGSize(width: 1920, height: 1080)

    func testIdentityKeepsSize() {
        assertRenderSize(
            naturalSize: landscape,
            transform: .identity,
            expectedRenderSize: landscape
        )
    }

    func testRotate90SwapsWidthAndHeight() {
        assertRenderSize(
            naturalSize: landscape,
            transform: CGAffineTransform(rotationAngle: .pi / 2),
            expectedRenderSize: CGSize(width: 1080, height: 1920)
        )
    }

    func testRotate180KeepsSize() {
        assertRenderSize(
            naturalSize: landscape,
            transform: CGAffineTransform(rotationAngle: .pi),
            expectedRenderSize: landscape
        )
    }

    func testRotate270SwapsWidthAndHeight() {
        assertRenderSize(
            naturalSize: landscape,
            transform: CGAffineTransform(rotationAngle: -.pi / 2),
            expectedRenderSize: CGSize(width: 1080, height: 1920)
        )
    }

    /// 前置摄像头竖拍：旋转叠加水平镜像。
    func testFrontCameraMirroredPortrait() {
        assertRenderSize(
            naturalSize: landscape,
            transform: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0),
            expectedRenderSize: CGSize(width: 1080, height: 1920)
        )
    }

    /// 奇数尺寸必须向下对齐到偶数，否则 H.264 / HEVC 编码会话建不起来。
    func testOddSizeAlignsDownToEven() {
        assertRenderSize(
            naturalSize: CGSize(width: 1921, height: 1081),
            transform: .identity,
            expectedRenderSize: CGSize(width: 1920, height: 1080)
        )
    }

    /// 小于 2 像素判为非法尺寸，交给上层报错而不是喂给编码器。
    func testDegenerateSizeCollapsesToZero() {
        let size = VideoCompositionBuilder.renderSize(
            naturalSize: CGSize(width: 1, height: 1080),
            preferredTransform: .identity
        )
        XCTAssertEqual(size.width, 0)
    }

    private func assertRenderSize(
        naturalSize: CGSize,
        transform: CGAffineTransform,
        expectedRenderSize: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let size = VideoCompositionBuilder.renderSize(
            naturalSize: naturalSize,
            preferredTransform: transform
        )
        XCTAssertEqual(size.width, expectedRenderSize.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(size.height, expectedRenderSize.height, accuracy: 0.5, file: file, line: line)
    }
}

// MARK: - 布局解析

final class LayoutResolverTests: XCTestCase {

    private let canvas = CGSize(width: 1000, height: 1000)

    private func config(
        anchor: WatermarkLayout.Anchor = .preset(.bottomRight),
        margin: CGFloat = 0.05,
        sizing: WatermarkSizing = .relativeWidth(0.2),
        rotation: CGFloat = 0,
        tiling: WatermarkTiling? = nil
    ) -> WatermarkConfig {
        WatermarkConfig(items: [
            WatermarkItem(
                content: .image(TestSupport.solidImage(size: CGSize(width: 50, height: 50), color: .blue)),
                layout: WatermarkLayout(
                    anchor: anchor,
                    margin: .all(margin),
                    sizing: sizing,
                    rotation: rotation,
                    tiling: tiling
                )
            )
        ])
    }

    func testBottomRightInTopLeftSpace() throws {
        let placements = try LayoutResolver.resolve(
            config: config(),
            canvasSize: canvas
        )
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.size.width, 200, accuracy: 1)
        // 可用区 (50,50,900,900)，水印 200 宽贴右下：中心 = 50 + 100 + 700
        XCTAssertEqual(placement.center.x, 850, accuracy: 1)
        XCTAssertEqual(placement.center.y, 850, accuracy: 1)
    }

    /// 图片与视频共用同一份布局解析，同一配置在两种介质上必须解析出同一个位置。
    ///
    /// 早期视频侧走的是 CALayer（左下原点），得在解析时翻一次 y；现在视频叠加图也用
    /// CoreGraphics 画（左上原点），翻转这一步连同它带来的一整类 bug 一起没有了。
    func testResolveIsMediumAgnostic() throws {
        let placements = try LayoutResolver.resolve(config: config(), canvasSize: canvas)
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.center.x, 850, accuracy: 1)
        XCTAssertEqual(placement.center.y, 850, accuracy: 1)
    }

    func testTopLeftAnchor() throws {
        let placements = try LayoutResolver.resolve(
            config: config(anchor: .preset(.topLeft)),
            canvasSize: canvas
        )
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.center.x, 150, accuracy: 1)
        XCTAssertEqual(placement.center.y, 150, accuracy: 1)
    }

    func testRelativeAnchorIgnoresMargin() throws {
        let placements = try LayoutResolver.resolve(
            config: config(anchor: .relative(CGPoint(x: 0.25, y: 0.75))),
            canvasSize: canvas
        )
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.center.x, 250, accuracy: 1)
        XCTAssertEqual(placement.center.y, 750, accuracy: 1)
    }

    /// 旋转后用外接矩形做边界约束，倾斜角标不应被画布边缘裁掉。
    func testRotationShrinksAvailableArea() throws {
        let rotated = try LayoutResolver.resolve(
            config: config(rotation: .pi / 4),
            canvasSize: canvas
        )
        let placement = try XCTUnwrap(rotated.first)
        let bounding = LayoutResolver.boundingSize(of: placement.size, rotation: .pi / 4)
        XCTAssertLessThanOrEqual(placement.center.x + bounding.width / 2, 950.5)
        XCTAssertLessThanOrEqual(placement.center.y + bounding.height / 2, 950.5)
    }

    func testSizingModes() {
        let intrinsic = CGSize(width: 100, height: 50)
        XCTAssertEqual(
            WatermarkSizing.relativeWidth(0.5).resolve(intrinsicSize: intrinsic, canvasSize: canvas),
            CGSize(width: 500, height: 250)
        )
        XCTAssertEqual(
            WatermarkSizing.relativeHeight(0.5).resolve(intrinsicSize: intrinsic, canvasSize: canvas),
            CGSize(width: 1000, height: 500)
        )
        XCTAssertEqual(
            WatermarkSizing.intrinsic.resolve(intrinsicSize: intrinsic, canvasSize: canvas),
            intrinsic
        )
    }

    /// 平铺必须收敛到上限内，否则 4K 画布会生成数百个 sublayer 拖垮合成。
    func testTilingRespectsMaxCount() throws {
        let tiling = WatermarkTiling(
            spacing: CGSize(width: 0.01, height: 0.01),
            angle: 0,
            isStaggered: false,
            maxTileCount: 12
        )
        let placements = try LayoutResolver.resolve(
            config: config(sizing: .relativeWidth(0.05), tiling: tiling),
            canvasSize: canvas
        )
        XCTAssertFalse(placements.isEmpty)
        XCTAssertLessThanOrEqual(placements.count, 12)
    }

    func testOrderedItemsSortByZIndex() {
        let makeItem: (Int) -> WatermarkItem = { zIndex in
            WatermarkItem(
                content: .text("z\(zIndex)"),
                layout: WatermarkLayout(zIndex: zIndex)
            )
        }
        let config = WatermarkConfig(items: [makeItem(5), makeItem(-1), makeItem(2)])
        let order: [Int] = config.orderedItems.map(\.layout.zIndex)
        XCTAssertEqual(order, [-1, 2, 5])
    }

    func testEmptyItemsThrows() {
        XCTAssertThrowsError(
            try LayoutResolver.resolve(
                config: WatermarkConfig(items: []),
                canvasSize: canvas
            )
        )
    }
}

// MARK: - 叠加图预合成

/// 视频侧把水印预先拍平成叠加图，分组规则决定了混合模式与前后次序还对不对。
final class WatermarkCompositorTests: XCTestCase {

    private let canvas = CGSize(width: 100, height: 100)

    private func placement(_ blendMode: CGBlendMode) throws -> ResolvedPlacement {
        let image = TestSupport.solidImage(size: CGSize(width: 10, height: 10), color: .red)
        return ResolvedPlacement(
            raster: try WatermarkRasterizer.rasterize(
                .image(image),
                targetSize: CGSize(width: 10, height: 10),
                canvasSize: canvas
            ),
            center: CGPoint(x: 50, y: 50),
            size: CGSize(width: 10, height: 10),
            rotation: 0,
            opacity: 1,
            blendMode: blendMode
        )
    }

    /// 混合模式相同的相邻实例合并成一张图，逐帧阶段就只有一次混合。
    func testSameBlendModeCollapsesToOneGroup() throws {
        let groups = WatermarkCompositor.makeOverlayGroups(
            [try placement(.normal), try placement(.normal), try placement(.normal)],
            canvasSize: canvas
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.blendMode, CGBlendMode.normal)
    }

    /// 分组必须按相邻切段而不是字典归类，否则 zIndex 定下的前后次序会被打乱。
    func testGroupingPreservesOrder() throws {
        let groups = WatermarkCompositor.makeOverlayGroups(
            [try placement(.normal), try placement(.multiply), try placement(.normal)],
            canvasSize: canvas
        )
        XCTAssertEqual(groups.map(\.blendMode), [CGBlendMode.normal, .multiply, .normal])
    }

    /// 叠加图必须铺满整个画布，否则与 sourceImage 对不齐。
    func testOverlayCoversWholeCanvas() throws {
        let groups = WatermarkCompositor.makeOverlayGroups([try placement(.normal)], canvasSize: canvas)
        let image = try XCTUnwrap(groups.first?.image)
        XCTAssertEqual(CGFloat(image.width), canvas.width)
        XCTAssertEqual(CGFloat(image.height), canvas.height)
    }

    func testBlendModeMapsToCoreImageFilter() {
        XCTAssertEqual(CGBlendMode.multiply.coreImageFilterName, "CIMultiplyBlendMode")
        XCTAssertEqual(CGBlendMode.normal.coreImageFilterName, "CISourceOverCompositing")
        // 映射不到的混合模式退回正常叠加，而不是崩掉或静默丢弃
        XCTAssertEqual(CGBlendMode.saturation.coreImageFilterName, "CISourceOverCompositing")
    }
}

// MARK: - 图片管线

final class ImageWatermarkTests: XCTestCase {

    private let renderer = ImageWatermarkRenderer()

    func testWatermarkIsDrawnAtBottomRight() async throws {
        let base = TestSupport.solidImage(size: CGSize(width: 200, height: 200), color: .red)
        let mark = TestSupport.solidImage(size: CGSize(width: 20, height: 20), color: .blue)

        let config = WatermarkConfig(items: [
            WatermarkItem(
                content: .image(mark),
                layout: WatermarkLayout(
                    anchor: .preset(.bottomRight),
                    margin: .zero,
                    sizing: .relativeWidth(0.25)
                ),
                style: WatermarkStyle(opacity: 1)
            )
        ])

        let result = try await renderer.applyWatermark(to: base, config: config)
        let corner = TestSupport.pixel(in: result.image, at: CGPoint(x: 190, y: 190))
        XCTAssertGreaterThan(corner.blue, 0.8, "右下角应为水印的蓝色")
        let center = TestSupport.pixel(in: result.image, at: CGPoint(x: 20, y: 20))
        XCTAssertGreaterThan(center.red, 0.8, "左上角应保持底图红色")
    }

    /// 所有 8 种方向都要能正确渲染，且输出尺寸为方向校正后的尺寸。
    func testAllImageOrientations() async throws {
        let config = WatermarkConfig.bottomRightLogo(
            TestSupport.solidImage(size: CGSize(width: 10, height: 10), color: .green)
        )
        let orientations: [UIImage.Orientation] = [
            .up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored
        ]

        for orientation in orientations {
            let base = TestSupport.solidImage(size: CGSize(width: 120, height: 60), color: .red)
            let oriented = UIImage(cgImage: try XCTUnwrap(base.cgImage), scale: 1, orientation: orientation)
            let result = try await renderer.applyWatermark(to: oriented, config: config)

            // .left/.right 系列会把宽高互换，这正是 UIImage.draw 应用方向的结果
            let expected = oriented.size
            XCTAssertEqual(result.image.size.width, expected.width, accuracy: 1, "方向 \(orientation.rawValue)")
            XCTAssertEqual(result.image.size.height, expected.height, accuracy: 1, "方向 \(orientation.rawValue)")
        }
    }

    func testEmptyConfigThrows() async {
        let base = TestSupport.solidImage(size: CGSize(width: 50, height: 50), color: .red)
        do {
            _ = try await renderer.applyWatermark(to: base, config: WatermarkConfig(items: []))
            XCTFail("空配置应当抛错")
        } catch {
            XCTAssertTrue(error is WatermarkError)
        }
    }

    func testMissingFileThrows() async {
        let url = URL(fileURLWithPath: "/tmp/watermarkkit-not-exist-\(UUID().uuidString).jpg")
        do {
            _ = try await renderer.applyWatermark(
                to: .fileURL(url),
                config: WatermarkConfig.bottomRightLogo(TestSupport.solidImage(size: .init(width: 8, height: 8), color: .white))
            )
            XCTFail("不存在的文件应当抛错")
        } catch let error as WatermarkError {
            guard case .fileNotFound = error else {
                return XCTFail("期望 fileNotFound，实得 \(error)")
            }
        } catch {
            XCTFail("期望 WatermarkError，实得 \(error)")
        }
    }
}

// MARK: - 元数据

final class ImageMetadataTests: XCTestCase {

    private let renderer = ImageWatermarkRenderer()

    override func tearDown() {
        WatermarkKit.cleanupTemporaryFiles()
        super.tearDown()
    }

    private func makeConfig(preservesMetadata: Bool, preservesLocation: Bool) -> WatermarkConfig {
        var config = WatermarkConfig.bottomRightLogo(
            TestSupport.solidImage(size: CGSize(width: 10, height: 10), color: .white)
        )
        config.output = OutputConfig(
            imageFormat: .jpeg(quality: 0.9),
            preservesMetadata: preservesMetadata,
            preservesLocation: preservesLocation,
            destination: .temporary
        )
        return config
    }

    func testMetadataPreservedAndLocationStripped() async throws {
        let source = try XCTUnwrap(TestSupport.jpegWithMetadata())
        let result = try await renderer.applyWatermark(
            to: .data(source),
            config: makeConfig(preservesMetadata: true, preservesLocation: false)
        )
        XCTAssertTrue(result.metadataPreserved)

        let properties = try XCTUnwrap(ImageEncoder.readMetadata(from: Data(contentsOf: try XCTUnwrap(result.fileURL))))
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "WatermarkKit", "TIFF 元数据应当保留")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "GPS 默认必须被剥离")
        // 像素已在渲染时正过来，方向要重置为 up，否则解码方会二次旋转
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        XCTAssertEqual(orientation, CGImagePropertyOrientation.up.rawValue)
    }

    func testLocationKeptWhenExplicitlyEnabled() async throws {
        let source = try XCTUnwrap(TestSupport.jpegWithMetadata())
        let result = try await renderer.applyWatermark(
            to: .data(source),
            config: makeConfig(preservesMetadata: true, preservesLocation: true)
        )
        let properties = try XCTUnwrap(ImageEncoder.readMetadata(from: Data(contentsOf: try XCTUnwrap(result.fileURL))))
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary], "显式开启后 GPS 应当保留")
    }

    func testMetadataDroppedWhenDisabled() async throws {
        let source = try XCTUnwrap(TestSupport.jpegWithMetadata())
        let result = try await renderer.applyWatermark(
            to: .data(source),
            config: makeConfig(preservesMetadata: false, preservesLocation: false)
        )
        let properties = try XCTUnwrap(ImageEncoder.readMetadata(from: Data(contentsOf: try XCTUnwrap(result.fileURL))))
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "关闭元数据保留后不应带上源图的 TIFF Make")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    /// UIImage 输入拿不到原始元数据，结果必须如实标记而不是谎报成功。
    func testUIImageInputReportsNoMetadata() async throws {
        let base = TestSupport.solidImage(size: CGSize(width: 60, height: 60), color: .red)
        let result = try await renderer.applyWatermark(
            to: .image(base),
            config: makeConfig(preservesMetadata: true, preservesLocation: false)
        )
        XCTAssertFalse(result.metadataPreserved, "UIImage 输入不可能保住 EXIF")
    }
}

// MARK: - 导出预设

final class ExportPresetTests: XCTestCase {

    private let size1080p = CGSize(width: 1920, height: 1080)

    func testHighestKeepsHighQualityForNormalSource() {
        // 1080p30 约 7.5 Mbps，属正常码率，不应降档
        let candidates = VideoExportPresetResolver.candidates(
            for: .highest,
            renderSize: size1080p,
            frameRate: 30,
            sourceDataRate: 7_500_000,
            avoidsFileSizeInflation: true
        )
        XCTAssertEqual(candidates.first, AVAssetExportPresetHEVCHighestQuality)
    }

    /// 低码率素材若按最高预设导出，文件会反而变大。
    func testLowBitrateSourceDowngrades() {
        let candidates = VideoExportPresetResolver.candidates(
            for: .highest,
            renderSize: size1080p,
            frameRate: 30,
            sourceDataRate: 800_000,
            avoidsFileSizeInflation: true
        )
        XCTAssertEqual(candidates.first, AVAssetExportPresetMediumQuality)
    }

    func testDowngradeDisabled() {
        let candidates = VideoExportPresetResolver.candidates(
            for: .highest,
            renderSize: size1080p,
            frameRate: 30,
            sourceDataRate: 800_000,
            avoidsFileSizeInflation: false
        )
        XCTAssertEqual(candidates.first, AVAssetExportPresetHEVCHighestQuality)
    }

    func testUnknownDataRateDoesNotDowngrade() {
        let candidates = VideoExportPresetResolver.candidates(
            for: .highest,
            renderSize: size1080p,
            frameRate: 30,
            sourceDataRate: 0,
            avoidsFileSizeInflation: true
        )
        XCTAssertEqual(candidates.first, AVAssetExportPresetHEVCHighestQuality)
    }
}

// MARK: - 临时文件

final class TemporaryFileTests: XCTestCase {

    func testDiscardRemovesTaskDirectoryOnly() throws {
        let manager = TemporaryFileManager.shared
        let first = try manager.makeURL(fileExtension: "mp4")
        let second = try manager.makeURL(fileExtension: "mp4")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        manager.discard(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: second.path),
            "清理单个任务不能波及并发进行的其他任务"
        )
        manager.cleanupAll()
    }

    /// 业务方自己指定的路径是用户的文件，Kit 不能碰。
    func testDiscardIgnoresExternalPath() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("wmk-external-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: external)

        TemporaryFileManager.shared.discard(external)

        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        try? FileManager.default.removeItem(at: external)
    }
}

// MARK: - 视频方向端到端

/// 方向的矩阵测试（`OrientationTests`）只验证画布尺寸，不验证「水印最终画在了哪个角」。
///
/// 这里跑完整管线并抽帧做像素断言。方向由 `applyingCIFiltersWithHandler` 依据轨道的
/// `preferredTransform` 施加，我们只按算出来的 renderSize 画叠加图 —— 两者一旦对不上
/// （画布算错、叠加图与 sourceImage 没对齐），水印就会跑到别的角或者被裁掉，
/// 这类错误只有端到端才测得出来。
final class VideoOrientationEndToEndTests: XCTestCase {

    private let landscape = CGSize(width: 640, height: 360)
    private var portrait: CGSize { CGSize(width: landscape.height, height: landscape.width) }

    private var generatedFiles: [URL] = []

    override func tearDown() {
        generatedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        generatedFiles.removeAll()
        WatermarkKit.cleanupTemporaryFiles()
        super.tearDown()
    }

    func testIdentityOrientation() async throws {
        try await assertBottomRightWatermark(transform: .identity, expectedRenderSize: landscape)
    }

    func testRotate90Orientation() async throws {
        try await assertBottomRightWatermark(
            transform: CGAffineTransform(rotationAngle: .pi / 2),
            expectedRenderSize: portrait
        )
    }

    func testRotate180Orientation() async throws {
        try await assertBottomRightWatermark(
            transform: CGAffineTransform(rotationAngle: .pi),
            expectedRenderSize: landscape
        )
    }

    func testRotate270Orientation() async throws {
        try await assertBottomRightWatermark(
            transform: CGAffineTransform(rotationAngle: -.pi / 2),
            expectedRenderSize: portrait
        )
    }

    /// 前置摄像头竖拍：旋转叠加水平镜像。
    func testFrontCameraMirroredOrientation() async throws {
        try await assertBottomRightWatermark(
            transform: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0),
            expectedRenderSize: portrait
        )
    }

    // MARK: -

    private func assertBottomRightWatermark(
        transform: CGAffineTransform,
        expectedRenderSize: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sourceURL = try await VideoTestSupport.makeVideo(transform: transform, naturalSize: landscape)
        generatedFiles.append(sourceURL)

        let result = try await WatermarkKit.videoRenderer.applyWatermark(
            to: .url(sourceURL),
            config: Self.makeConfig()
        )
        generatedFiles.append(result.fileURL)

        XCTAssertEqual(
            result.renderSize.width, expectedRenderSize.width,
            accuracy: 2, "renderSize 宽度不符", file: file, line: line
        )
        XCTAssertEqual(
            result.renderSize.height, expectedRenderSize.height,
            accuracy: 2, "renderSize 高度不符", file: file, line: line
        )

        let frame = try await VideoTestSupport.middleFrame(of: result.fileURL)
        let size = frame.size

        // 水印占短边 30%，右下角内缩 12px 必定落在水印内
        let corner = TestSupport.pixel(in: frame, at: CGPoint(x: size.width - 12, y: size.height - 12))
        XCTAssertGreaterThan(corner.red, 0.55, "右下角应为水印黄色", file: file, line: line)
        XCTAssertGreaterThan(corner.green, 0.55, "右下角应为水印黄色", file: file, line: line)
        XCTAssertLessThan(corner.blue, 0.45, "右下角应为水印黄色", file: file, line: line)

        let opposite = TestSupport.pixel(in: frame, at: CGPoint(x: 12, y: 12))
        XCTAssertGreaterThan(
            opposite.blue, 0.45,
            "左上角应保持底图蓝色；水印若出现在这里，说明画布方向与叠加图对不上",
            file: file, line: line
        )
        XCTAssertLessThan(opposite.red, 0.45, "左上角不该出现水印", file: file, line: line)
    }

    private static func makeConfig() -> WatermarkConfig {
        var config = WatermarkConfig(items: [
            WatermarkItem(
                content: .image(TestSupport.solidImage(size: CGSize(width: 100, height: 100), color: .yellow)),
                layout: WatermarkLayout(
                    anchor: .preset(.bottomRight),
                    margin: .zero,
                    sizing: .relativeShorterEdge(0.3)
                ),
                style: WatermarkStyle(opacity: 1)
            )
        ])
        // 视频不支持 memoryOnly，必须落盘
        config.output.destination = .temporary
        return config
    }
}

// MARK: - 测试辅助

enum TestSupport {

    static func solidImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    struct PixelColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    /// 读取指定位置的像素颜色（左上原点）。
    static func pixel(in image: UIImage, at point: CGPoint) -> PixelColor {
        guard let cgImage = image.cgImage else { return PixelColor(red: 0, green: 0, blue: 0) }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.translateBy(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return PixelColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255
        )
    }

    /// 构造一张同时带 TIFF、EXIF、GPS 的 JPEG，用于验证元数据流转。
    static func jpegWithMetadata() -> Data? {
        guard let cgImage = solidImage(size: CGSize(width: 80, height: 60), color: .orange).cgImage else {
            return nil
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "WatermarkKit",
                kCGImagePropertyTIFFModel: "UnitTest",
                kCGImagePropertyTIFFDateTime: "2026:09:14 10:30:00"
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:14 10:30:00"
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.23,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.47,
                kCGImagePropertyGPSLongitudeRef: "E"
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

/// 视频测试素材的生成与抽帧。
enum VideoTestSupport {

    /// 底图颜色，与水印的黄色形成最大对比，H.264 的 YUV 往返不会把两者混淆。
    static let backgroundColor = UIColor.blue

    /// 用 `AVAssetWriter` 现场生成一段纯色测试视频，并写入指定的 `preferredTransform`。
    ///
    /// 注意：模拟器上的 H.264 编码依赖 VideoToolbox 的软件编码器，个别 Xcode / 模拟器组合下不可用。
    /// 若这几个用例只在模拟器上失败而真机通过，优先怀疑编码器而不是水印逻辑。
    static func makeVideo(
        transform: CGAffineTransform,
        naturalSize: CGSize,
        frameCount: Int = 12,
        frameRate: CMTimeScale = 30
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wmk-source-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height)
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform      // 被测的就是这个值如何影响最终方向

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(naturalSize.width),
                kCVPixelBufferHeightKey as String: Int(naturalSize.height)
            ]
        )

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VideoTestSupport", code: -1)
        }
        writer.startSession(atSourceTime: .zero)

        let buffer = try makePixelBuffer(size: naturalSize, color: backgroundColor)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate))
        }
        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VideoTestSupport", code: -2)
        }
        return url
    }

    /// 抽取视频中间一帧。
    static func middleFrame(of url: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: time)
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func makePixelBuffer(size: CGSize, color: UIColor) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "VideoTestSupport", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.setFillColor(color.cgColor)
        context?.fill(CGRect(origin: .zero, size: size))
        return buffer
    }
}

// swiftlint:enable file_length
