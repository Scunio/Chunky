import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

extension PlatformImage {
    var asSwiftUIImage: Image {
        #if os(iOS) || os(visionOS)
        Image(uiImage: self)
        #elseif os(macOS)
        Image(nsImage: self)
        #endif
    }

    static func from(data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    var pngData: Data? {
        #if os(iOS) || os(visionOS)
        return self.pngData()
        #elseif os(macOS)
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    var cgImageRepresentation: CGImage? {
        #if os(iOS) || os(visionOS)
        return self.cgImage
        #elseif os(macOS)
        return self.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    static func from(cgImage: CGImage) -> PlatformImage {
        #if os(iOS) || os(visionOS)
        return PlatformImage(cgImage: cgImage)
        #elseif os(macOS)
        return PlatformImage(cgImage: cgImage, size: .zero)
        #endif
    }
}
