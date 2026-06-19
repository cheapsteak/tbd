import SwiftUI

struct RowTooltipPreference: Equatable {
    let text: String
    let anchor: Anchor<CGRect>

    static func == (lhs: RowTooltipPreference, rhs: RowTooltipPreference) -> Bool {
        // Compare only text; anchors are reference-equal so we can't use == directly.
        lhs.text == rhs.text
    }
}

struct RowTooltipPreferenceKey: PreferenceKey {
    static let defaultValue: RowTooltipPreference? = nil

    static func reduce(value: inout RowTooltipPreference?, nextValue: () -> RowTooltipPreference?) {
        // Last non-nil wins: only the currently-hovered row element publishes a value.
        if let next = nextValue() { value = next }
    }
}

struct RowTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
            .fixedSize()
    }
}
