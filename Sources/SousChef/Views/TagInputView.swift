import SwiftUI

/// Pill/tag input with food-dictionary autocomplete.
/// Adds a tag when the user types a comma or taps a suggestion.
struct TagInputView: View {
    let placeholder: String
    @Binding var tags: [String]

    @State private var inputText = ""
    @State private var suggestions: [String] = []
    @State private var foodNames: [String] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Pills
            if !tags.isEmpty {
                PillFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagPill(text: tag) { tags.removeAll { $0 == tag } }
                    }
                }
            }

            // Input field
            TextField(placeholder, text: $inputText)
                .focused($isFocused)
                .foregroundStyle(Color.scTextPrimary)
                .onChange(of: inputText) { _, newVal in
                    if newVal.hasSuffix(",") {
                        let tag = String(newVal.dropLast()).trimmingCharacters(in: .whitespaces)
                        if !tag.isEmpty { addTag(tag) }
                        inputText = ""
                    } else {
                        refreshSuggestions(for: newVal)
                    }
                }
                .onSubmit {
                    let tag = inputText.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { addTag(tag) }
                    inputText = ""
                }

            // Autocomplete strip
            if !suggestions.isEmpty && isFocused {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                addTag(s)
                                inputText = ""
                            } label: {
                                Text(s)
                                    .font(.scCaption)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, 4)
                                    .background(Color.scAccent.opacity(0.15))
                                    .foregroundStyle(Color.scAccent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if foodNames.isEmpty {
                foodNames = FoodDictionary.shared.allNames()
            }
        }
    }

    private func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        suggestions = []
    }

    private func refreshSuggestions(for query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { suggestions = []; return }
        suggestions = foodNames
            .filter { $0.hasPrefix(q) && !tags.contains($0) }
            .prefix(6)
            .map { $0 }
    }
}

// MARK: - TagPill

private struct TagPill: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.scCaption)
                .foregroundStyle(Color.scTextPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.scTextSecondary)
            }
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.scSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.scBorder, lineWidth: 1))
    }
}

// MARK: - PillFlowLayout

/// Wrapping flow layout for pill collections.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 8

    struct CacheData {}
    func makeCache(subviews: Subviews) -> CacheData { CacheData() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        flow(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let result = flow(in: bounds.width, subviews: subviews)
        for (idx, sv) in subviews.enumerated() {
            sv.place(
                at: CGPoint(x: result.positions[idx].x + bounds.minX,
                            y: result.positions[idx].y + bounds.minY),
                proposal: .unspecified
            )
        }
    }

    private struct FlowResult { var positions: [CGPoint]; var size: CGSize }

    private func flow(in maxWidth: CGFloat, subviews: Subviews) -> FlowResult {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        var positions: [CGPoint] = []
        var totalW: CGFloat = 0

        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth, x > 0 {
                y += rowH + spacing; x = 0; rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            totalW = max(totalW, x - spacing)
        }
        return FlowResult(positions: positions, size: CGSize(width: totalW, height: y + rowH))
    }
}
