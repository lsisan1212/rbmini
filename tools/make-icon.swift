#!/usr/bin/env swift
// Renders the RBMini app icon at 1024x1024 into Resources/icon-1024.png
// Pure CoreGraphics, no external assets. Run: swift tools/make-icon.swift

import AppKit

let S: CGFloat = 1024
let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// MARK: - squircle background

let inset: CGFloat = 44
let bgRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let bg = CGPath(roundedRect: bgRect, cornerWidth: 208, cornerHeight: 208, transform: nil)

// drop shadow under the whole tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.42))
ctx.addPath(bg)
ctx.setFillColor(rgb(0x0B0D12))
ctx.fillPath()
ctx.restoreGState()

// gradient body
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [rgb(0x272C36), rgb(0x15181E), rgb(0x090B0F)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 0, y: S - inset),
                       end: CGPoint(x: S * 0.55, y: inset),
                       options: [])

// soft cyan bloom behind the waveform
let bloom = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [rgb(0x2FD8FF, 0.30), rgb(0x2FD8FF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 660, y: 480), startRadius: 20,
                        endCenter: CGPoint(x: 660, y: 480), endRadius: 430, options: [])
ctx.restoreGState()

// inner hairline
ctx.saveGState()
ctx.addPath(bg)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: - remote body

let bodyRect = CGRect(x: 210, y: 250, width: 220, height: 460)
let body = CGPath(roundedRect: bodyRect, cornerWidth: 110, cornerHeight: 110, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.55))
ctx.addPath(body)
ctx.setFillColor(rgb(0xF7F9FC))
ctx.fillPath()
ctx.restoreGState()

// body sheen
ctx.saveGState()
ctx.addPath(body)
ctx.clip()
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [rgb(0xFFFFFF), rgb(0xD9DFEA)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 210, y: 710),
                        end: CGPoint(x: 430, y: 250), options: [])
ctx.restoreGState()

// mic ring
ctx.saveGState()
ctx.setStrokeColor(rgb(0x1BC7F0))
ctx.setLineWidth(15)
ctx.strokeEllipse(in: CGRect(x: 320 - 26, y: 596 - 26, width: 52, height: 52))
ctx.restoreGState()

// two buttons
for cy in [CGFloat(508), CGFloat(442)] {
    ctx.setFillColor(rgb(0x11151C))
    ctx.fillEllipse(in: CGRect(x: 320 - 19, y: cy - 19, width: 38, height: 38))
}

// MARK: - waveform

let bars: [CGFloat] = [104, 190, 292, 190, 104]
let barW: CGFloat = 54
let gap: CGFloat = 20
var x: CGFloat = 498
let midY: CGFloat = 480

ctx.saveGState()
let wavePath = CGMutablePath()
var xs: [CGFloat] = []
for h in bars {
    wavePath.addRoundedRect(in: CGRect(x: x, y: midY - h / 2, width: barW, height: h),
                            cornerWidth: barW / 2, cornerHeight: barW / 2)
    xs.append(x)
    x += barW + gap
}
ctx.addPath(wavePath)
ctx.clip()
let waveGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0x35E8C4), rgb(0x3FC9FF), rgb(0x6AA8FF)] as CFArray,
                          locations: [0, 0.5, 1])!
ctx.drawLinearGradient(waveGrad,
                        start: CGPoint(x: xs.first!, y: 0),
                        end: CGPoint(x: xs.last! + barW, y: 0), options: [])
ctx.restoreGState()

// glow pass on the wave
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: rgb(0x35D9FF, 0.55))
ctx.addPath(wavePath)
ctx.setFillColor(rgb(0x35D9FF, 0.9))
ctx.fillPath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let dest = outDir.appendingPathComponent("icon-1024.png")
try png.write(to: dest)
print("wrote \(dest.path)")
