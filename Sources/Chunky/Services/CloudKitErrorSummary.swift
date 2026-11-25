import CloudKit
import Foundation

/// Turns a CloudKit error into one Diagnostica line that says *why*.
///
/// `NSPersistentCloudKitContainer` export failures surface as "Failed to modify some records":
/// a `CKError.partialFailure` whose real causes (per record) sit in `partialErrorsByItemID`.
/// Logging only `localizedDescription` hid them, so a recurring export failure couldn't be told
/// apart between harmless (a conflict Core Data retries, a record already deleted elsewhere) and
/// real (a quota, a schema problem, a record rejected every time).
enum CloudKitErrorSummary {
    static func describe(_ error: Error) -> String {
        let ckError = (error as? CKError) ?? underlyingCKError(of: error)
        guard let ckError else { return error.localizedDescription }
        guard ckError.code == .partialFailure,
              let partials = ckError.partialErrorsByItemID, !partials.isEmpty
        else { return describeSingle(ckError) }

        // "serverRecordChanged ×3 (CD_ComicEntity)" — grouped, counted, most frequent first.
        var counts: [String: Int] = [:]
        for (_, itemError) in partials {
            let key = (itemError as? CKError).map(describeSingle) ?? itemError.localizedDescription
            counts[key, default: 0] += 1
        }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        return "partialFailure su \(partials.count) record: " + parts.joined(separator: ", ")
    }

    /// Code name, plus the record type when CloudKit hands back the server's copy (conflicts).
    static func describeSingle(_ error: CKError) -> String {
        var text = codeName(error.code)
        if let serverRecord = error.serverRecord {
            text += " (\(serverRecord.recordType))"
        } else if error.code == .batchRequestFailed {
            text += " (scartato con il resto del lotto)"
        }
        return text
    }

    private static func underlyingCKError(of error: Error) -> CKError? {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let next = current?.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
            if let ckError = next as? CKError { return ckError }
            if next.domain == CKError.errorDomain { return CKError(_nsError: next) }
            current = next
        }
        return nil
    }

    static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .serverRecordChanged: return "serverRecordChanged"
        case .unknownItem: return "unknownItem"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneNotFound: return "zoneNotFound"
        case .quotaExceeded: return "quotaExceeded"
        case .limitExceeded: return "limitExceeded"
        case .constraintViolation: return "constraintViolation"
        case .invalidArguments: return "invalidArguments"
        case .permissionFailure: return "permissionFailure"
        case .networkFailure: return "networkFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .zoneBusy: return "zoneBusy"
        case .notAuthenticated: return "notAuthenticated"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .userDeletedZone: return "userDeletedZone"
        case .changeTokenExpired: return "changeTokenExpired"
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        default: return "codice \(code.rawValue)"
        }
    }
}
