#!/usr/bin/env swift
// Genera le immagini e il PDF usati come fixture dei test.
//
// Le fixture sono committate, non generate a ogni run: `Unrar.swift` sa solo decomprimere e
// non esiste un compressore RAR utilizzabile in CI, quindi il .cbr va comunque versionato.
// Avere metà fixture generate e metà committate significherebbe due fonti di verità.
// Questo script serve a rigenerarle in modo riproducibile, e documenta come sono fatte.
//
// Uso: swift Scripts/make-fixtures.swift <cartella-output>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

/// I colori vanno creati NELLO spazio del contesto. `CGColor(red:green:blue:alpha:)` crea il
/// colore in generic RGB, e la conversione verso sRGB sposta le componenti (un rosso puro
/// diventa ~rgb(255, 38, 0)): le fixture non conterrebbero i colori che dichiarano.
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: rgb, components: [r, g, b, 1])!
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// PNG 8×8 di tinta unita: il colore identifica la pagina, così un test può verificare
/// non solo che l'immagine esista ma che sia *quella giusta* nell'ordine giusto.
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

/// PDF di 2 pagine con un quadrante colorato in ALTO A SINISTRA e il resto bianco.
/// L'asimmetria è il punto: un rendering capovolto verticalmente mette il colore in basso,
/// ed è esattamente il bug che il ramo macOS di PDFPageProvider aveva.
func writePDF(named name: String) {
    let url = outDir.appendingPathComponent(name) as CFURL
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 200)
    let ctx = CGContext(url, mediaBox: &mediaBox, nil)!
    // Colore diverso per pagina, così un test può anche verificare l'indice di pagina.
    for (index, pageColor) in [color(1, 0, 0), color(0, 0, 1)].enumerated() {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(color(1, 1, 1))
        ctx.fill(mediaBox)
        ctx.setFillColor(pageColor)
        // In spazio PDF la y cresce verso l'alto: la metà superiore è il quadrante "in alto".
        ctx.fill(CGRect(x: 0, y: mediaBox.height / 2, width: mediaBox.width / 2, height: mediaBox.height / 2))
        ctx.endPDFPage()
        _ = index
    }
    ctx.closePDF()
    print("scritto \(name)")
}

writePDF(named: "sample.pdf")
