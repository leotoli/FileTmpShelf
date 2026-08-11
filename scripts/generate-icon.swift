#!/usr/bin/env swift

// generate-icon.swift — 用 CoreGraphics 生成 FileTmpShelf 全套 macOS 图标 PNG。
// 设计：蓝色→紫色渐变背景 + 托盘（tray.full 风格：圆角边框 + 三格分隔 + 格内小卡片）。
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

    // 1. 背景渐变（整幅全出血，系统负责外圆角遮罩）
    let bgColors = [rgba(0.16, 0.42, 0.95), rgba(0.34, 0.24, 0.90)] as CFArray
    let bgGrad = CGGradient(colorsSpace: sRGB, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // 2. 顶部光泽
    let glossColors = [rgba(1, 1, 1, 0.16), rgba(1, 1, 1, 0.0)] as CFArray
    let gloss = CGGradient(colorsSpace: sRGB, colors: glossColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        gloss,
        startCenter: CGPoint(x: S * 0.5, y: S * 0.9), startRadius: 0,
        endCenter: CGPoint(x: S * 0.5, y: S * 0.9), endRadius: S * 0.9,
        options: []
    )

    // 3. 托盘投影
    ctx.setFillColor(rgba(0, 0, 0, 0.16))
    ctx.addPath(roundedRectPath(CGRect(x: 170 * u, y: 300 * u, width: 660 * u, height: 420 * u), radius: 50 * u))
    ctx.fillPath()

    // 4. 托盘外框
    ctx.setStrokeColor(rgba(1, 1, 1, 0.95))
    ctx.setLineWidth(26 * u)
    ctx.addPath(roundedRectPath(CGRect(x: 170 * u, y: 312 * u, width: 660 * u, height: 420 * u), radius: 50 * u))
    ctx.strokePath()

    // 5. 托盘内底（半透明）
    ctx.setFillColor(rgba(1, 1, 1, 0.30))
    ctx.addPath(roundedRectPath(CGRect(x: 196 * u, y: 338 * u, width: 608 * u, height: 366 * u), radius: 36 * u))
    ctx.fillPath()

    // 6. 分隔竖线（三等分 → 3 格）
    ctx.setStrokeColor(rgba(1, 1, 1, 0.55))
    ctx.setLineWidth(12 * u)
    ctx.setLineCap(.round)
    for cx in [399.0, 601.0] {
        ctx.move(to: CGPoint(x: cx * u, y: 344 * u))
        ctx.addLine(to: CGPoint(x: cx * u, y: 690 * u))
    }
    ctx.strokePath()

    // 7. 格内"文件"圆角小卡
    ctx.setFillColor(rgba(1, 1, 1, 0.92))
    let cards: [(CGFloat, CGFloat)] = [(297, 520), (512, 520), (703, 520)]
    for (cx, cy) in cards {
        ctx.addPath(roundedRectPath(CGRect(x: (cx - 34) * u, y: (cy - 52) * u, width: 68 * u, height: 104 * u), radius: 16 * u))
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
