import Foundation
#if os(iOS)
import MetricKit
#endif

/// Cattura locale di crash/hang tramite MetricKit — nessun invio remoto: i payload arrivano
/// solo a questa app, con il ritardo imposto da Apple (in pratica solo su dispositivo fisico,
/// quasi mai in simulatore). Vengono solo aggiunti a `DiagnosticLog`, consultabile da
/// Impostazioni > Diagnostica. MetricKit non esiste su macOS: lì il toggle non ha effetto.
enum CrashReportManager {
    static func configure() {
        #if os(iOS)
        guard UserDefaults.standard.object(forKey: "crashReportingEnabled") as? Bool ?? true else { return }
        MXMetricManager.shared.add(Subscriber.shared)
        #endif
    }
}

#if os(iOS)
private final class Subscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = Subscriber()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                DiagnosticLog.log("MetricKit: \(crashes.count) crash diagnostic(s) ricevuti")
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                DiagnosticLog.log("MetricKit: \(hangs.count) hang diagnostic(s) ricevuti")
            }
        }
    }
}
#endif
