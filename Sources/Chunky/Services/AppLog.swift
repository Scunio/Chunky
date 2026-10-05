import Foundation

/// Log dettagliato visibile sia in console Xcode (NSLog) sia nel file Diagnostica.
/// Da usare nei flussi delicati (salvataggio credenziali, Core Data) dove un
/// `try?` silenzioso nasconderebbe la causa. Mai segreti: solo lunghezze,
/// booleani, id e codici di stato.
enum AppLog {
    static func log(_ message: String) {
        NSLog("[Chunky] %@", message)
        DiagnosticLog.log(message)
    }

    /// ATTENZIONE: stampa VALORI sensibili (password!) SOLO in console Xcode,
    /// MAI nel file Diagnostica (che può essere condiviso). Solo per debug locale:
    /// RIMUOVERE tutte le chiamate prima di qualsiasi release pubblica.
    static func secret(_ message: String) {
        NSLog("[Chunky-SECRET] %@", message)
    }
}
