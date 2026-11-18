import SwiftUI

private struct ReaderCloseActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set when the reader is hosted as a root overlay (tvOS) instead of a system presentation,
    /// where `dismiss` has nothing to dismiss.
    var readerCloseAction: (() -> Void)? {
        get { self[ReaderCloseActionKey.self] }
        set { self[ReaderCloseActionKey.self] = newValue }
    }
}

/// Drop-in replacement for `@Environment(\.dismiss)` in the reader: uses the host's close
/// action when one is provided, the system dismiss otherwise.
@propertyWrapper
struct ReaderDismiss: DynamicProperty {
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.readerCloseAction) private var closeOverride

    var wrappedValue: () -> Void {
        if let closeOverride { return closeOverride }
        let systemDismiss = systemDismiss
        return { systemDismiss() }
    }
}
