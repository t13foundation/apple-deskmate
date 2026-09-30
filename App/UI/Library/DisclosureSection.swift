import SwiftUI

/// A disclosure whose accessibility is explicit. Only the header button carries the label, hint and
/// expanded/collapsed value; the content is a sibling, so its rows stay separate accessibility elements.
///
/// SwiftUI's `DisclosureGroup` with an `.accessibilityLabel` on the group replaced every child row with that one
/// label in the real app ("Sources, 1" instead of each source), so the label is never put on a container here.
struct DMDisclosure<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let label: String
    let hint: String
    let header: Header
    let content: Content

    init(
        isExpanded: Binding<Bool>,
        label: String,
        hint: String,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        _isExpanded = isExpanded
        self.label = label
        self.hint = hint
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    header
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(hint)

            if isExpanded {
                content
                    .padding(.leading, 12 + DS.Spacing.s)
            }
        }
        .dmAnimation(value: isExpanded)
    }
}
