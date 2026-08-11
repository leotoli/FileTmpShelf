#!/usr/bin/env swift

// generate-icon.swift — 用 CoreGraphics 生成 FileTmpShelf 全套 macOS 图标 PNG。
// 设计（v2，苹果 Big Sur 风格）：
//   - 背景：青→蓝→紫 斜向细腻渐变（squircle 由系统遮罩，图标全出血）
//   - 符号：白色托盘（tray）+ 中央浮起一张"文件"卡片，右下角小折角
//   - 细节：顶部柔光、托盘投影、微圆角端点
// 用法：swift scripts/generate-icon.swift [输出目录（默认 FileTmpShelf/Assets.xcassets/AppIcon.appiconset）]
// 可重复运行，幂等。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 输出目录

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultOut = scriptDir
    .deletingLastPathComponent()
    .appendingPathComponent("FileTmpShelf/Assets.xcassets/AppIcon.appiconset")
let outDir: URL
if CommandLine.arguments.count > 1 {
    outDir = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    outDir = defaultOut
}

// MARK: - 绘制

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func roundedRectPath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// 连续曲率 squircle 的近似路径（用 4 段二次贝塞尔模拟 iOS/macOS 图标圆角）
func squirclePath(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let r = rect.width * 0.2237   // Big Sur 图标圆角近似比例
    let w = rect.width
    let h = rect.height
    // 控制点系数（squircle 近似）
    let k: CGFloat = 0.5578
    let cx = rect.minX, cy = rect.minY

    path.move(to: CGPoint(x: cx + r, y: cy))
    path.addLine(to: CGPoint(x: cx + w - r, y: cy))
    path.addQuadCurve(
        to: CGPoint(x: cx + w, y: cy + r),
        control: CGPoint(x: cx + w - r * (1 - k), y: cy + r * k)
    )
    path.addLine(to: CGPoint(x: cx + w, y: cy + h - r))
    path.addQuadCurve(
        to: CGPoint(x: cx + w - r, y: cy + h),
        control: CGPoint(x: cx + w - r * k, y: cy + h - r * (1 - k))
    )
    path.addLine(to: CGPoint(x: cx + r, y: cy + h))
    path.addQuadCurve(
        to: CGPoint(x: cx, y: cy + h - r),
        control: CGPoint(x: cx + r * (1 - k), y: cy + h - r * k)
    )
    path.addLine(to: CGPoint(x: cx, y: cy + r))
    path.addQuadCurve(
        to: CGPoint(x: cx + r, y: cy),
        control: CGPoint(x: cx + r * k, y: cy + r * (1 - k))
    )
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let px = size
    let S = CGFloat(px)   // 画布边长
    let u = S / 1024.0    // 缩放系数（1024 设计稿基准）

    let ctx = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 1. 背景斜向渐变（青 → 蓝 → 紫，视觉更现代）
    let bgColors = [
        rgba(0.18, 0.62, 0.98),   // 顶部青蓝
        rgba(0.28, 0.42, 0.95),   // 中部蓝
        rgba(0.45, 0.28, 0.92)    // 底部紫
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: sRGB, colors: bgColors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: S),
        end: CGPoint(x: S, y: 0),
        options: []
    )

    // 2. 顶部柔光（径向，位置偏高，更含蓄）
    let glossColors = [rgba(1, 1, 1, 0.20), rgba(1, 1, 1, 0.0)] as CFArray
    let gloss = CGGradient(colorsSpace: sRGB, colors: glossColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        gloss,
        startCenter: CGPoint(x: S * 0.5, y: S * 0.92), startRadius: 0,
        endCenter: CGPoint(x: S * 0.5, y: S * 0.92), endRadius: S * 0.75,
        options: []
    )

    // 3. 底部细微暗角（增加层次）
    let shadeColors = [rgba(0, 0, 0, 0.0), rgba(0, 0, 0, 0.12)] as CFArray
    let shade = CGGradient(colorsSpace: sRGB, colors: shadeColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        shade,
        startCenter: CGPoint(x: S * 0.5, y: S * 0.15), startRadius: S * 0.2,
        endCenter: CGPoint(x: S * 0.5, y: S * 0.15), endRadius: S * 0.95,
        options: []
    )

    // 4. 托盘投影
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10 * u),
        blur: 28 * u,
        color: rgba(0, 0, 0, 0.35)
    )

    // 5. 托盘主体（白色，圆角，中空感：外框 + 内凹底）
    ctx.setFillColor(rgba(1, 1, 1, 0.96))
    ctx.addPath(roundedRectPath(CGRect(x: 212 * u, y: 332 * u, width: 600 * u, height: 380 * u), radius: 64 * u))
    ctx.fillPath()

    // 6. 托盘内底（半透明白，模拟凹陷）
    ctx.setFillColor(rgba(0.30, 0.45, 0.90, 0.20))
    ctx.addPath(roundedRectPath(CGRect(x: 244 * u, y: 366 * u, width: 536 * u, height: 316 * u), radius: 44 * u))
    ctx.fillPath()

    // 7. 顶部"文件"卡片（浮起，有折角）
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 16 * u, color: rgba(0, 0, 0, 0.28))
    let cardRect = CGRect(x: 372 * u, y: 208 * u, width: 280 * u, height: 330 * u)
    ctx.setFillColor(rgba(1, 1, 1, 0.97))
    ctx.addPath(roundedRectPath(cardRect, radius: 36 * u))
    ctx.fillPath()

    // 卡片折角（右下角小三角）
    let fold = CGMutablePath()
    let fw = 96 * u
    fold.move(to: CGPoint(x: cardRect.maxX - fw, y: cardRect.maxY))
    fold.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY - fw))
    fold.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY))
    fold.closeSubpath()
    ctx.setFillColor(rgba(0.28, 0.42, 0.95, 0.55))
    ctx.addPath(fold)
    ctx.fillPath()

    // 8. 卡片上的"文档线"（三道白色/浅色线条，代表文件内容）
    ctx.setStrokeColor(rgba(0.30, 0.45, 0.90, 0.85))
    ctx.setLineWidth(20 * u)
    ctx.setLineCap(.round)
    for (i, y) in [0.0, 1.0, 2.0].enumerated() {
        let lineY = cardRect.minY + 88 * u + CGFloat(i) * 58 * u
        ctx.move(to: CGPoint(x: cardRect.minX + 56 * u, y: lineY))
        ctx.addLine(to: CGPoint(x: cardRect.maxX - (y == 2.0 ? 160.0 : 56.0) * u, y: lineY))
        ctx.strokePath()
    }

    // 9. 托盘内三格分隔线（淡）
    ctx.setStrokeColor(rgba(0.30, 0.45, 0.90, 0.35))
    ctx.setLineWidth(8 * u)
    ctx.setLineCap(.round)
    for cx in [400.0, 624.0] {
        ctx.move(to: CGPoint(x: cx * u, y: 380 * u))
        ctx.addLine(to: CGPoint(x: cx * u, y: 668 * u))
    }
    ctx.strokePath()

    // 10. 托盘内"小圆点"（每个格一个小圆，代表文件项）
    ctx.setFillColor(rgba(0.30, 0.45, 0.90, 0.50))
    for cx in [322.0, 512.0, 702.0] {
        ctx.addPath(CGPath(ellipseIn: CGRect(x: (cx - 22) * u, y: 500 * u, width: 44 * u, height: 44 * u), transform: nil))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

// MARK: - 写文件

let spec: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for item in spec {
        let image = drawIcon(size: item.px)
        let url = outDir.appendingPathComponent(item.name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fputs("无法创建图像目标: \(item.name)\n", stderr)
            exit(1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            fputs("写入失败: \(item.name)\n", stderr)
            exit(1)
        }
        print("生成 \(item.name) (\(item.px)x\(item.px))")
    }
    print("图标已写入: \(outDir.path)")
} catch {
    fputs("错误: \(error)\n", stderr)
    exit(1)
}
