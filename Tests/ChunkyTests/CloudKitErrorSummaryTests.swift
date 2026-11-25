import CloudKit
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// "Failed to modify some records" da solo non dice niente: la riga di Diagnostica deve
/// riportare le cause per record dentro il `partialFailure`.
struct CloudKitErrorSummaryTests {
    private func ckError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
        CKError(_nsError: NSError(domain: CKError.errorDomain, code: code.rawValue, userInfo: userInfo))
    }

    @Test("Il partialFailure elenca le cause per record, raggruppate e contate")
    func partialFailureListsCauses() {
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        let partials: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "a", zoneID: zone): ckError(.unknownItem),
            CKRecord.ID(recordName: "b", zoneID: zone): ckError(.batchRequestFailed),
            CKRecord.ID(recordName: "c", zoneID: zone): ckError(.batchRequestFailed)
        ]
        let error = ckError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partials])

        let line = CloudKitErrorSummary.describe(error)
        #expect(line.hasPrefix("partialFailure su 3 record"))
        #expect(line.contains("batchRequestFailed (scartato con il resto del lotto) ×2"))
        #expect(line.contains("unknownItem"))
    }

    @Test("L'errore CloudKit annidato dentro quello di Core Data viene trovato")
    func findsUnderlyingCKError() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: CKError.errorDomain, code: CKError.Code.quotaExceeded.rawValue)
        ])
        #expect(CloudKitErrorSummary.describe(wrapped) == "quotaExceeded")
    }

    @Test("Un errore non CloudKit resta la sua descrizione")
    func plainErrorPassesThrough() {
        let error = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boh"])
        #expect(CloudKitErrorSummary.describe(error) == "boh")
    }
}
