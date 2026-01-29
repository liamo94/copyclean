#!/usr/bin/env swift

import AppKit

// Generate app icon from SF Symbol
let sizes: [(Int, String)] = [
    (16, "16"),
    (32, "16@2x"),
    (32, "32"),
    (64, "32@2x"),
    (128, "128"),
    (256, "128@2x"),
    (256, "256"),
    (512, "256@2x"),
    (512, "512"),
    (1024, "512@2x")
]

let outputDir = "Pastedit/Assets.xcassets/AppIcon.appiconset"

// Create directory if needed
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    // Draw gradient background
    let gradient = NSGradient(colors: [
        NSColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0),
        NSColor(red: 0.3, green: 0.4, blue: 0.9, alpha: 1.0)
    ])!

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    gradient.draw(in: path, angle: -45)

    // Draw SF Symbol
    let symbolSize = CGFloat(size) * 0.55
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolRect = NSRect(
            x: (CGFloat(size) - symbolSize) / 2,
            y: (CGFloat(size) - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )

        // Draw white symbol
        NSColor.white.setFill()
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()

    // Save as PNG
    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        let filename = "\(outputDir)/icon_\(name).png"
        try? pngData.write(to: URL(fileURLWithPath: filename))
        print("Generated: \(filename)")
    }
}

// Generate Contents.json
let contentsJson = """
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try? contentsJson.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("Generated: Contents.json")
print("Done! Rebuild your app in Xcode.")
