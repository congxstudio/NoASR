// 在macOS运行：swift scripts/render-readme-brand.swift
// 沿用应用图标和定稿矢量字标，输出README专用的2倍分辨率深浅色组合。
import AppKit
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let iconSource = CGImageSourceCreateWithURL(root.appendingPathComponent("macos/Assets/AppIcon.png") as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(iconSource, 0, nil),
      let document = CGPDFDocument(root.appendingPathComponent("macos/Assets/OneMore-wordmark.pdf") as CFURL),
      let wordmark = document.page(at: 1) else {
    fatalError("请在仓库根目录运行，所需品牌资源不存在")
}
let output = root.appendingPathComponent("docs/assets")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for dark in [false, true] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 360,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: 2, y: 2)
    context.imageInterpolation = .high
    let wordmarkRect = NSRect(x: 304, y: 87, width: 238, height: 238 * 135 / 742)
    let titleColor = dark ? NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1)
                          : NSColor(srgbRed: 0.345, green: 0.38, blue: 0.431, alpha: 1)
    let cg = context.cgContext
    cg.saveGState()
    cg.clip(to: wordmarkRect)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.saveGState()
    cg.translateBy(x: wordmarkRect.minX, y: wordmarkRect.minY)
    cg.scaleBy(x: wordmarkRect.width / 742, y: wordmarkRect.height / 135)
    cg.drawPDFPage(wordmark)
    cg.restoreGState()
    cg.setBlendMode(.sourceIn)
    cg.setFillColor(titleColor.cgColor)
    cg.fill(wordmarkRect)
    cg.endTransparencyLayer()
    cg.restoreGState()
    let subtitleColor = dark ? NSColor(srgbRed: 0.64, green: 0.69, blue: 0.76, alpha: 1)
                             : NSColor(srgbRed: 0.47, green: 0.51, blue: 0.57, alpha: 1)
    let subtitle = NSAttributedString(string: "又一个语音输入法", attributes: [
        .font: NSFont(name: "PingFangSC-Regular", size: 20) ?? NSFont.systemFont(ofSize: 20),
        .foregroundColor: subtitleColor,
        .kern: 1.0
    ])
    subtitle.draw(at: NSPoint(x: 305, y: 54))
    context.cgContext.draw(icon, in: NSRect(x: 178, y: 38, width: 104, height: 104))
    NSGraphicsContext.restoreGraphicsState()
    let name = "readme-brand-\(dark ? "dark" : "light").png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    print("生成 docs/assets/\(name)，1440×360")
}
