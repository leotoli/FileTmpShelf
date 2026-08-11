#!/usr/bin/env swift

// generate-icon.swift — 用 CoreGraphics 生成 FileTmpShelf 全套 macOS 图标 PNG。
// 设计（v3，macOS 26 Liquid Glass 玻璃风格）：
//   - 背景：通透的青→蓝渐变，带大范围柔和光晕（模拟玻璃透光）
//   - 主元素：半透明"玻璃托盘"，上缘高光描边，内凹底有光反射
//   - 中央：一张半透明玻璃文档卡片（无小圆点，保持简洁）
//   - 细节：边缘 1px 亮边、顶部/侧面反光带、底部柔和投影
// 用法：swift scripts/generate-icon.swift [输出目录]
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
    let S = CGFloat(px)
    let u = S / 1024.0

    let ctx = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 1. 背景：柔和青蓝渐变（活泼但降低饱和度，护眼）
    let bgColors = [
        rgba(0.45, 0.80, 0.96),   // 顶部柔和青
        rgba(0.44, 0.62, 0.94),   // 中部柔和蓝
        rgba(0.60, 0.48, 0.90)    // 底部柔和紫
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: sRGB, colors: bgColors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: S),
        end: CGPoint(x: S, y: 0),
        options: []
    )

    // 2. 大范围光晕（左上角主光源，玻璃反光）
    let glowColors = [rgba(1, 1, 1, 0.30), rgba(1, 1, 1, 0.0)] as CFArray
    let glow = CGGradient(colorsSpace: sRGB, colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: S * 0.30, y: S * 0.85), startRadius: 0,
        endCenter: CGPoint(x: S * 0.30, y: S * 0.85), endRadius: S * 0.85,
        options: []
    )

    // 3. 底部柔和投影（托盘）
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14 * u),
        blur: 40 * u,
        color: rgba(0.05, 0.10, 0.40, 0.40)
    )

    // 4. 玻璃托盘主体（半透明白 + 渐变 → 玻璃质感）
    let trayRect = CGRect(x: 212 * u, y: 344 * u, width: 600 * u, height: 360 * u)
    let trayPath = roundedRectPath(trayRect, radius: 72 * u)
    ctx.saveGState()
    ctx.addPath(trayPath)
    ctx.clip()

    // 4a. 托盘内渐变（顶部亮、底部略暗的玻璃）
    let glassColors = [
        rgba(1, 1, 1, 0.55),
        rgba(1, 1, 1, 0.32),
        rgba(1, 1, 1, 0.18)
    ] as CFArray
    let glass = CGGradient(colorsSpace: sRGB, colors: glassColors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        glass,
        start: CGPoint(x: trayRect.midX, y: trayRect.maxY),
        end: CGPoint(x: trayRect.midX, y: trayRect.minY),
        options: []
    )

    // 4b. 托盘内壁斜向反光（左上光源）
    let innerGlow = CGGradient(colorsSpace: sRGB, colors: [rgba(1, 1, 1, 0.45), rgba(1, 1, 1, 0.0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        innerGlow,
        startCenter: CGPoint(x: trayRect.minX + 80 * u, y: trayRect.maxY - 60 * u), startRadius: 0,
        endCenter: CGPoint(x: trayRect.minX + 80 * u, y: trayRect.maxY - 60 * u), endRadius: 260 * u,
        options: []
    )
    ctx.restoreGState()

    // 4c. 托盘上缘高光（液态玻璃边缘亮线）
    ctx.setStrokeColor(rgba(1, 1, 1, 0.85))
    ctx.setLineWidth(10 * u)
    ctx.addPath(roundedRectPath(trayRect.insetBy(dx: 5 * u, dy: 5 * u), radius: 66 * u))
    ctx.strokePath()

    // 5. 中央玻璃文档卡片（半透明，浮起）
    let cardRect = CGRect(x: 377 * u, y: 206 * u, width: 270 * u, height: 318 * u)
    let cardPath = roundedRectPath(cardRect, radius: 40 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 20 * u, color: rgba(0.05, 0.10, 0.40, 0.35))
    ctx.addPath(cardPath)
    ctx.fillPath()

    // 5a. 卡片玻璃渐变
    ctx.addPath(cardPath)
    ctx.clip()
    let cardGlass = CGGradient(colorsSpace: sRGB, colors: [rgba(1, 1, 1, 0.62), rgba(1, 1, 1, 0.28)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        cardGlass,
        start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
        end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
        options: []
    )
    ctx.restoreGState()

    // 5b. 卡片上缘高光
    ctx.setStrokeColor(rgba(1, 1, 1, 0.90))
    ctx.setLineWidth(8 * u)
    ctx.addPath(roundedRectPath(cardRect.insetBy(dx: 4 * u, dy: 4 * u), radius: 36 * u))
    ctx.strokePath()

    // 5c. 卡片内容线 → 参考图风格：蓝紫系细线（去暖色，收敛）
    let accentColors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.62, 0.72, 0.95),   // 柔和蓝
        (0.72, 0.64, 0.94),   // 柔和紫
        (0.55, 0.80, 0.92)    // 柔和青
    ]
    for (i, c) in accentColors.enumerated() {
        let lineY = cardRect.minY + 84 * u + CGFloat(i) * 56 * u
        let lineMaxX = cardRect.maxX - (i == 2 ? 150.0 : 52.0) * u
        let linePath = CGMutablePath()
        linePath.move(to: CGPoint(x: cardRect.minX + 52 * u, y: lineY))
        linePath.addLine(to: CGPoint(x: lineMaxX, y: lineY))
        ctx.setStrokeColor(rgba(c.0, c.1, c.2, 0.85))
        ctx.setLineWidth(18 * u)
        ctx.setLineCap(.round)
        ctx.addPath(linePath)
        ctx.strokePath()
    }

    // 6. 托盘内底微弱反光带（玻璃透光底部）
    ctx.saveGState()
    ctx.addPath(roundedRectPath(CGRect(x: 250 * u, y: 372 * u, width: 524 * u, height: 296 * u), radius: 48 * u))
    ctx.clip()
    let bottomShine = CGGradient(colorsSpace: sRGB, colors: [rgba(1, 1, 1, 0.0), rgba(1, 1, 1, 0.22)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bottomShine,
        start: CGPoint(x: 0, y: 372 * u),
        end: CGPoint(x: 0, y: 668 * u),
        options: []
    )
    ctx.restoreGState()

    // 7. 活泼装饰已移除（用户反馈参考图不需要闪光星）：
    //    保持玻璃托盘 + 文档卡片的简洁结构，聚焦"暂存"语义。

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
