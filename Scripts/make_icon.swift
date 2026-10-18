import AppKit
import Foundation

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(red: 0.035, green: 0.065, blue: 0.065, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let mint = NSColor(red: 0.47, green: 0.94, blue: 0.73, alpha: 1)
mint.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: 122, y: 122, width: 780, height: 780)).fill()
mint.withAlphaComponent(0.24).setStroke()
let circle = NSBezierPath(ovalIn: NSRect(x: 188, y: 188, width: 648, height: 648))
circle.lineWidth = 4
circle.stroke()
mint.setFill()
let heights: [CGFloat] = [150, 290, 420, 290, 150]
for index in 0..<5 {
    NSBezierPath(roundedRect: NSRect(x: 303 + CGFloat(index) * 88, y: (1024 - heights[index]) / 2,
                                    width: 64, height: heights[index]), xRadius: 32, yRadius: 32).fill()
}
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
let path = "Sources/Watch/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: path + "/AppIcon.png"))
let contents = """
{"images":[{"filename":"AppIcon.png","idiom":"watch-marketing","size":"1024x1024","scale":"1x"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(toFile: path + "/Contents.json", atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(toFile: "Sources/Watch/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
