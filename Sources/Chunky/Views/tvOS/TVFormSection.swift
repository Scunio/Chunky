#if os(tvOS)
import SwiftUI

/// A form field: plain-text label on the left, its value in a wide pill on the right —
/// matching Infuse's "Aggiungi condivisione" screen (confirmed via real on-device photo of a
/// well-made tvOS app), not a merged card with dividers (that's the iOS/iPadOS Settings look,
/// tried first and confirmed wrong for tvOS) and not a boxed label above a full-width field
/// (the original `Form`-based layout this replaces).
struct TVFormFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Text(label)
                .font(.body)
                .frame(width: 260, alignment: .leading)
            content
                .frame(maxWidth: .infinity)
        }
    }
}

/// Section grouping label — small, understated, above a run of `TVFormFieldRow`s. Infuse's own
/// simple "Aggiungi condivisione" form has no section headers at all (single-purpose form), but
/// Chunky's form genuinely spans distinct groups (server/credentials/automation) that need
/// separation — kept minimal rather than the heavier all-caps card header tried before.
struct TVFormSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.bold())
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }
}

/// Primary form action — a bold, full-width filled pill at the bottom of the form (Infuse's
/// "Aggiungi" button), not a small top-corner toolbar button.
struct TVFormPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
        .buttonStyle(.card)
        .tint(.orange)
    }
}

/// A toggle rendered the same way as every other field (label left, pill right) — "On"/"Off"
/// text, not a system switch. Matches Infuse's own toggle rows exactly (confirmed via photo:
/// "Scansione automatica … On", same pill shape/focus behavior as the text fields above it).
struct TVFormToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        TVFormFieldRow(label: label) {
            Button(action: { isOn.toggle() }) {
                Text(isOn ? "On" : "Off")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.card)
        }
    }
}

/// A full-width pill combining a title and expand/collapse chevron — Infuse's "Avanzate" row:
/// not a section header sitting above a group, the pill itself IS the disclosure control.
struct TVFormDisclosureRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .buttonStyle(.card)
    }
}

#Preview {
    struct PreviewContainer: View {
        @State private var isToggleOn = true
        @State private var isExpanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                TVFormSectionLabel(title: "Server")
                TVFormFieldRow(label: "Nome") {
                    Text("Il mio NAS")
                }
                TVFormToggleRow(label: "Scansione automatica", isOn: $isToggleOn)
                TVFormDisclosureRow(title: "Avanzate", isExpanded: $isExpanded)
                TVFormPrimaryButton(title: "Salva", action: {})
            }
            .padding(48)
        }
    }
    return PreviewContainer()
}
#endif
