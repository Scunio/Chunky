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
}
