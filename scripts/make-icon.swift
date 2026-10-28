// Draws the app icon: a track's fade envelope, the silence after it, and the next track rising.
// Usage: swift scripts/make-icon.swift Support/AppIcon.icns
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil))
    ctx.setFillColor(color(0x1E1E2E))
    ctx.fillPath()

    let floor = tile.minY + tile.height * 0.3
    let maxHeight = tile.height * 0.42
    let barWidth = tile.width * 0.045
    let step = tile.width * 0.07
    var x = tile.minX + tile.width * 0.13
    // quartic fade-in, a hold, quartic fade-out; each bar a Mocha accent
    let shape: [Double] = [0.06, 0.32, 0.8, 1, 1, 1, 0.8, 0.32, 0.06]
    let accents: [UInt32] = [0xF5C2E7, 0xCBA6F7, 0xB4BEFE, 0x89B4FA, 0x74C7EC, 0x94E2D5, 0xA6E3A1, 0xF9E2AF, 0xFAB387]
    for (level, accent) in zip(shape, accents) {
        let height = max(barWidth, maxHeight * level)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: floor, width: barWidth, height: height), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(color(accent))
        ctx.fillPath()
        x += step
    }
    // the silence
    ctx.setFillColor(color(0x6C7086))
    for _ in 0..<2 {
        x += step * 0.15
        ctx.fillEllipse(in: CGRect(x: x, y: floor, width: barWidth, height: barWidth))
        x += step * 0.85
    }
    // the next track's first bar
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: floor, width: barWidth, height: maxHeight * 0.32), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.setFillColor(color(0x45475A))
    ctx.fillPath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let output = URL(filePath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote \(output.path)")
