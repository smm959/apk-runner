import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let radius = s * 0.225
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1),
        CGColor(red: 0.05, green: 0.55, blue: 0.33, alpha: 1)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    // Android-ish head + antennae
    let headW = s * 0.46, headH = s * 0.36
    let headRect = CGRect(x: (s - headW) / 2, y: s * 0.28, width: headW, height: headH)
    let head = CGPath(roundedRect: headRect, cornerWidth: headH * 0.42, cornerHeight: headH * 0.42, transform: nil)
    ctx.addPath(head)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()

    // eyes
    ctx.setFillColor(CGColor(red: 0.05, green: 0.55, blue: 0.33, alpha: 1))
    let eyeR = max(s * 0.018, 1.2)
    for dx in [-1.0, 1.0] as [CGFloat] {
        let c = CGPoint(x: s / 2 + dx * headW * 0.17, y: headRect.midY + headH * 0.06)
        ctx.fillEllipse(in: CGRect(x: c.x - eyeR, y: c.y - eyeR, width: eyeR * 2, height: eyeR * 2))
    }

    // antennae
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(max(s * 0.022, 1.5))
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: s * 0.5 - headW * 0.36, y: headRect.maxY - 1))
    ctx.addLine(to: CGPoint(x: s * 0.5 - headW * 0.52, y: headRect.maxY + headH * 0.30))
    ctx.move(to: CGPoint(x: s * 0.5 + headW * 0.36, y: headRect.maxY - 1))
    ctx.addLine(to: CGPoint(x: s * 0.5 + headW * 0.52, y: headRect.maxY + headH * 0.30))
    ctx.strokePath()

    // download arrow inside head for large sizes
    if size >= 128 {
        ctx.setStrokeColor(CGColor(red: 0.05, green: 0.55, blue: 0.33, alpha: 0.95))
        ctx.setLineWidth(max(s * 0.045, 2))
        ctx.move(to: CGPoint(x: s * 0.5, y: headRect.minY + headH * 0.20))
        ctx.addLine(to: CGPoint(x: s * 0.5, y: headRect.minY + headH * 0.58))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: s * 0.5 - headH * 0.16, y: headRect.minY + headH * 0.40))
        ctx.addLine(to: CGPoint(x: s * 0.5, y: headRect.minY + headH * 0.18))
        ctx.addLine(to: CGPoint(x: s * 0.5 + headH * 0.16, y: headRect.minY + headH * 0.40))
        ctx.strokePath()
    }

    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    if let d1 = drawIcon(size) {
        try? d1.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if let d2 = drawIcon(size * 2) {
        try? d2.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
print("iconset ready at \(iconset.path)")
