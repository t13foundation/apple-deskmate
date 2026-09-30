import SwiftUI

/// Content of one starter tile: the icon leads a title and one short supporting line.
/// Both lines are single lines, so every tile is exactly `DS.Layout.tileMinHeight` tall and tiles that share a row
/// are equal. The tile fills the width it is offered.
struct StarterTile: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: symbol)
                .font(.dmSection)
                .foregroundStyle(Color.dmBrandText)
                .frame(width: DS.Layout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.dmBody.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: DS.Layout.tileMinHeight, alignment: .leading)
    }
}
