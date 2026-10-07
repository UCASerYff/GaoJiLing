import AppKit
import Foundation

// Usage: swift Scripts/MakeIcon.swift [source PNG] [destination ICNS]
// Resizes the checked-in artwork only; it never redraws or changes the icon.
enum IconError: Error {
    case invalidInput(String)
    case renderFailed(Int)
}

let arguments = CommandLine.arguments
let input = arguments.count > 1 ? arguments[1] : "Assets/AppIcon.png"
let output = arguments.count > 2 ? arguments[2] : "Assets/AppIcon.icns"
let inputURL = URL(fileURLWithPath: input).standardizedFileURL
let outputURL = URL(fileURLWithPath: output).standardizedFileURL
guard let image = NSImage(contentsOf: inputURL), image.size.width > 0,
      image.size.width == image.size.height else {
    throw IconError.invalidInput(input)
}

let fileManager = FileManager.default
let temporary = fileManager.temporaryDirectory.appendingPathComponent("GaoJiLingIcon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporary) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw IconError.renderFailed(pixels)
        }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw IconError.renderFailed(pixels)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
// Store standard PNG representations directly in the ICNS container. This also
// works in build sandboxes where iconutil's image services are unavailable.
func lengthData(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let entries: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var body = Data()
for (kind, name) in entries {
    let png = try Data(contentsOf: iconset.appendingPathComponent(name))
    body.append(Data(kind.utf8))
    body.append(lengthData(png.count + 8))
    body.append(png)
}
var container = Data("icns".utf8)
container.append(lengthData(body.count + 8))
container.append(body)
try container.write(to: outputURL, options: .atomic)
print("Created \(outputURL.path)")
