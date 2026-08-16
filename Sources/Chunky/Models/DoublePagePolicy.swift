import CoreGraphics

/// Whether a two-page spread makes sense in the available space.
///
/// Two portrait pages side by side in a narrow window leave a huge gap above and
/// below (the combined image is too wide relative to the available height): double
/// page only makes sense with more horizontal than vertical space.
enum DoublePagePolicy {
    /// - Parameters:
    ///   - viewportSize: measured size of the reading area. `.zero` until it has
    ///     actually been measured (first layout) — in that case we assume yes, so as not to
    ///     deny double page just because layout hasn't happened yet.
    ///   - isCompactWidth: `true` on iPhone in portrait (compact size class): there double
    ///     page never makes sense regardless of the measured aspect ratio. On iPad and
    ///     on Mac, where there's no compact size class, `false` is passed and the decision
    ///     depends only on the aspect ratio.
    static func isAllowed(viewportSize: CGSize, isCompactWidth: Bool) -> Bool {
        guard !isCompactWidth else { return false }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return true }
        return viewportSize.width > viewportSize.height
    }
}
