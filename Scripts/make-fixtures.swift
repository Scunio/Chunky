#!/usr/bin/env swift
// Generates the images and PDF used as test fixtures.
//
// The fixtures are committed, not generated on every run: `Unrar.swift` only knows how to
// decompress, and there's no usable RAR compressor in CI, so the .cbr has to be versioned
// anyway. Having half generated and half committed fixtures would mean two sources of truth.
// This script exists to regenerate them reproducibly, and documents how they're made.
//
// Usage: swift Scripts/make-fixtures.swift <output-folder>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

/// Colors must be created IN the context's space. `CGColor(red:green:blue:alpha:)` creates the
/// color in generic RGB, and the conversion to sRGB shifts the components (a pure red
/// becomes ~rgb(255, 38, 0)): the fixtures wouldn't contain the colors they claim to.
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: rgb, components: [r, g, b, 1])!
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Solid-color 8×8 PNG: the color identifies the page, so a test can verify
/// not just that the image exists but that it's the *right one* in the right order.
func writePNG(named name: String, red: CGFloat, green: CGFloat, blue: CGFloat) {
    let ctx = makeContext(8)
    ctx.setFillColor(color(red, green, blue))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("scritto \(name)")
}

writePNG(named: "page_0001.png", red: 1, green: 0, blue: 0)
writePNG(named: "page_0002.png", red: 0, green: 1, blue: 0)
writePNG(named: "page_0003.png", red: 0, green: 0, blue: 1)

/// 2-page PDF with a colored quadrant in the TOP LEFT and the rest white.
/// The asymmetry is the point: a rendering flipped vertically puts the color at the bottom,
/// which is exactly the bug the macOS branch of PDFPageProvider had.
func writePDF(named name: String) {
    let url = outDir.appendingPathComponent(name) as CFURL
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 200)
    let ctx = CGContext(url, mediaBox: &mediaBox, nil)!
    // Different color per page, so a test can also verify the page index.
    for (index, pageColor) in [color(1, 0, 0), color(0, 0, 1)].enumerated() {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(color(1, 1, 1))
        ctx.fill(mediaBox)
        ctx.setFillColor(pageColor)
        // In PDF space y grows upward: the upper half is the "top" quadrant.
        ctx.fill(CGRect(x: 0, y: mediaBox.height / 2, width: mediaBox.width / 2, height: mediaBox.height / 2))
        ctx.endPDFPage()
        _ = index
    }
    ctx.closePDF()
    print("scritto \(name)")
}

writePDF(named: "sample.pdf")
