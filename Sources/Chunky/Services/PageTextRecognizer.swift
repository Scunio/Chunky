import Foundation
import CoreGraphics
import Vision

/// Una riga di testo trovata su una pagina, con il rettangolo che la racchiude.
///
/// `boundingBox` è **normalizzato (0...1) con origine in basso a sinistra**: è lo spazio di
/// `VNRecognizedTextObservation.boundingBox`, ed è anche quello che si ottiene dividendo i
/// bounds di una riga PDF per i bounds della sua pagina. Tenere un solo spazio per entrambe le
/// sorgenti evita che, più a valle, il disegno delle evidenziazioni debba sapere se il testo
/// arrivi dall'OCR o dal livello testo del PDF.
struct RecognizedTextLine: Codable, Equatable {
    let text: String
    let boundingBox: CGRect
}

/// OCR di una pagina con Vision. L'idea (e la soglia di confidenza) arrivano da Simple-Comic
/// <https://github.com/MaddTheSane/Simple-Comic>, MIT, che ha la stessa funzione su macOS: qui
/// il wrapper è riscritto in Swift e restituisce già le coordinate normalizzate che servono al
/// lettore, invece del layer di selezione AppKit che su SwiftUI non avrebbe senso.
enum PageTextRecognizer {
    /// Sotto questa confidenza l'osservazione viene scartata: sui fumetti i retini, i bordi
    /// delle vignette e gli effetti sonori producono facilmente "parole" che non esistono, e
    /// che nella ricerca sarebbero solo rumore.
    static let minimumConfidence: Float = 0.5

    /// Lingue passate a Vision: quelle preferite dal sistema che Vision sa davvero riconoscere,
    /// più l'inglese come rete di sicurezza. Senza il fallback, su un sistema impostato in una
    /// lingua non supportata la richiesta fallirebbe del tutto invece di leggere comunque i
    /// fumetti in inglese, che sono la maggioranza di quelli con testo latino.
    static let recognitionLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        guard !supported.isEmpty else { return ["en-US"] }

        var languages: [String] = []
        for preferred in Locale.preferredLanguages {
            // Locale.preferredLanguages restituisce tag completi ("it-IT"); Vision espone a
            // volte solo la lingua base ("it"). Proviamo entrambe le forme prima di scartarla.
            let base = String(preferred.prefix(while: { $0 != "-" }))
            if let match = supported.first(where: { $0 == preferred || $0 == base || $0.hasPrefix("\(base)-") }),
               !languages.contains(match) {
                languages.append(match)
            }
        }
        if let english = supported.first(where: { $0 == "en-US" }) ?? supported.first(where: { $0.hasPrefix("en") }),
           !languages.contains(english) {
            languages.append(english)
        }
        return languages.isEmpty ? ["en-US"] : languages
    }()

    static func recognizeLines(in cgImage: CGImage) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedTextLine(text: text, boundingBox: observation.boundingBox)
        }
    }

    /// Converte un `boundingBox` normalizzato nelle coordinate schermo con cui la pagina è
    /// effettivamente disegnata.
    ///
    /// Due trasformazioni, entrambe necessarie: la stessa geometria `scaledToFit` con cui il
    /// lettore centra la pagina (identica a quella di `PanelSelectionView.confirmSelection()`),
    /// **più** il ribaltamento verticale, perché SwiftUI ha l'origine in alto a sinistra e
    /// Vision in basso a sinistra. Dimenticare il ribaltamento non fa fallire nulla: mette
    /// semplicemente ogni evidenziazione nella metà sbagliata della pagina, per questo la
    /// conversione sta qui in un solo punto ed è coperta da test.
    static func screenRect(forNormalized box: CGRect, imageSize: CGSize, displaySize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              displaySize.width > 0, displaySize.height > 0 else { return .zero }

        let scale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = (displaySize.width - fittedSize.width) / 2
        let originY = (displaySize.height - fittedSize.height) / 2

        return CGRect(
            x: originX + box.minX * fittedSize.width,
            y: originY + (1 - box.maxY) * fittedSize.height,
            width: box.width * fittedSize.width,
            height: box.height * fittedSize.height
        )
    }
}
