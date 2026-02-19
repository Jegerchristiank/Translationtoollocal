#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: generate_dmg_background.swift <output.png> <width> <height>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
guard let width = Int(CommandLine.arguments[2]), let height = Int(CommandLine.arguments[3]), width > 0, height > 0 else {
    fputs("Width/height must be positive integers.\n", stderr)
    exit(1)
}

let canvas = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate bitmap context.\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.94, alpha: 1.0).setFill()
NSBezierPath(rect: canvas).fill()

if let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0)
]) {
    gradient.draw(in: canvas, angle: -90)
}

let footerRect = NSRect(x: 0, y: 0, width: canvas.width, height: 42)
NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.21, alpha: 0.96).setFill()
NSBezierPath(rect: footerRect).fill()

let arrow = "›" as NSString
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 1.0, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -1)
shadow.shadowBlurRadius = 2

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 96, weight: .black),
    .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 0.92),
    .paragraphStyle: paragraph,
    .shadow: shadow
]

let arrowSize = arrow.size(withAttributes: attributes)
let arrowRect = NSRect(
    x: (canvas.width - arrowSize.width) / 2,
    y: (canvas.height - arrowSize.height) / 2 + 6,
    width: arrowSize.width,
    height: arrowSize.height
)
arrow.draw(in: arrowRect, withAttributes: attributes)

NSGraphicsContext.restoreGraphicsState()

let outputURL = URL(fileURLWithPath: outputPath)
let ext = outputURL.pathExtension.lowercased()
let repType: NSBitmapImageRep.FileType = (ext == "tif" || ext == "tiff") ? .tiff : .png

guard let data = bitmap.representation(using: repType, properties: [:]) else {
    fputs("Failed to generate image data.\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: outputURL, options: .atomic)
