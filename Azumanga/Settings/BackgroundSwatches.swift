import SwiftUI

/// Rectangle swatches shared by the reader's per-manga view options and the main
/// Appearance settings.
struct BackgroundSwatches: View {
    @Binding var selection: PageBackground

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(PageBackground.allCases) { background in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background.color)
                        .frame(height: 36)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    selection == background
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.3),
                                    lineWidth: selection == background ? 2 : 1
                                )
                        }
                        .overlay(alignment: .topTrailing) {
                            if selection == background {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white, .tint)
                                    .padding(4)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { selection = background }

                    Text(background.displayName)
                        .font(.caption2)
                        .foregroundStyle(
                            selection == background ? Color.primary : Color.secondary
                        )
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(background.displayName)
                .accessibilityAddTraits(selection == background ? .isSelected : [])
            }
        }
    }
}

extension PageBackground {
    var color: Color {
        switch self {
        case .black: .black
        case .darkGray: Color(white: 0.12)
        case .white: .white
        }
    }
}
