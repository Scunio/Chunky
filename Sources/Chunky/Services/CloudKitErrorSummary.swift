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
        else { return describeSingle(ckError) + " — " + serverMessage(of: ckError) }

        // "serverRecordChanged ×3 (CD_ComicEntity)" — grouped, counted, most frequent first.
        var counts: [String: Int] = [:]
        for (_, itemError) in partials {
            let key = (itemError as? CKError).map(describeSingle) ?? itemError.localizedDescription
            counts[key, default: 0] += 1
        }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        var line = "partialFailure su \(partials.count) record: " + parts.joined(separator: ", ")
        // The server's own words for the real causes (not the batch casualties): for
        // invalidArguments they name the field or record type it refused, which is what tells
        // a schema gap apart from a bad value. One per distinct message, capped.
        let messages = partials.values.compactMap { $0 as? CKError }
            .filter { $0.code != .batchRequestFailed }
            .map { serverMessage(of: $0) }
        let distinct = Array(Set(messages)).sorted().prefix(3)
        if !distinct.isEmpty {
            line += " — " + distinct.joined(separator: " | ")
        }
        // The refused records' names (not the batch casualties): looked up in CloudKit Console
        // they show the record type and fields, i.e. exactly which data is being rejected.
        let refused = partials.filter { ($0.value as? CKError)?.code != .batchRequestFailed }
            .compactMap { entry -> String? in
                guard let recordID = entry.key.base as? CKRecord.ID else { return nil }
                return "\(recordID.recordName) in \(recordID.zoneID.zoneName)"
            }
            .sorted().prefix(3)
        if !refused.isEmpty {
            line += " — record: " + refused.joined(separator: ", ")
        }
        return line
    }

    /// The server explanation of a CloudKit error, trimmed for one log line. CloudKit often puts
    /// only an internal code on top ("CKInternalErrorDomain: 2006") and the readable reason —
    /// e.g. which field it refused — in an error nested under `NSUnderlyingErrorKey`, so the whole
    /// chain is walked and every descriptive text found is kept, deduplicated, in order.
    static func serverMessage(of error: CKError) -> String {
        var texts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 5 {
            for key in ["ServerErrorDescription", "NSDebugDescription", "CKErrorDescription", NSLocalizedFailureReasonErrorKey] {
                if let text = nsError.userInfo[key] as? String, !text.isEmpty { texts.append(text) }
            }
            texts.append("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        var seen = Set<String>()
        let unique = texts.filter { seen.insert($0).inserted }
        return String(unique.joined(separator: " / ").prefix(400))
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
