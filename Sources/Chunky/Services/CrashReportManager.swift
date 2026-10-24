import Foundation
#if os(iOS)
import MetricKit
#endif

/// Local capture of crashes/hangs via MetricKit — no remote submission: the payloads arrive
/// only to this app, with the delay imposed by Apple (in practice only on a physical device,
/// almost never in the simulator). They're only appended to `DiagnosticLog`, viewable from
/// Settings > Diagnostics. MetricKit doesn't exist on macOS: there, the toggle has no effect.
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
                for (index, crash) in crashes.enumerated() {
                    let exception = crash.exceptionReason.map {
                        "\($0.className) / \($0.exceptionName): \($0.composedMessage)"
                    } ?? "non disponibile"
                    let details = [
                        "MetricKit crash \(index + 1)/\(crashes.count)",
                        "versione=\(crash.applicationVersion)",
                        "terminazione=\(crash.terminationReason ?? "non disponibile")",
                        "eccezione=\(exception)",
                        "tipo=\(crash.exceptionType?.stringValue ?? "?")",
                        "codice=\(crash.exceptionCode?.stringValue ?? "?")",
                        "signal=\(crash.signal?.stringValue ?? "?")"
                    ].joined(separator: "; ")
                    DiagnosticLog.log(details)
                }
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                DiagnosticLog.log("MetricKit: \(hangs.count) hang diagnostic(s) ricevuti")
            }
        }
    }
}
#endif
