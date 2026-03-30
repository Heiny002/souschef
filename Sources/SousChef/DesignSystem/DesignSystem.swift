import SwiftUI

// MARK: - Color Tokens

extension Color {
    /// Near-black warm background — #0F0E0C
    static let scBackground = Color(hex: "#0F0E0C")
    /// Off-white primary text — #F5F0E8
    static let scTextPrimary = Color(hex: "#F5F0E8")
    /// Muted secondary text (60% opacity)
    static let scTextSecondary = Color(hex: "#F5F0E8").opacity(0.6)
    /// Amber accent — #C8813A
    static let scAccent = Color(hex: "#C8813A")
    /// Card / elevated surface — slightly lighter than background
    static let scSurface = Color(hex: "#1A1915")
    /// Divider and border (12% opacity)
    static let scBorder = Color(hex: "#F5F0E8").opacity(0.12)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

extension Font {
    // Lora serif — display and content headings
    static let scDisplay   = Font.custom("Lora-Bold",     size: 28, relativeTo: .largeTitle)
    static let scHeadline  = Font.custom("Lora-SemiBold", size: 22, relativeTo: .title)
    static let scTitle     = Font.custom("Lora-Regular",  size: 18, relativeTo: .title2)

    // SF Pro — UI chrome, labels, body
    static let scBody      = Font.system(size: 16, weight: .regular)
    static let scLabel     = Font.system(size: 14, weight: .medium)
    static let scCaption   = Font.system(size: 13, weight: .regular)
}

// MARK: - Spacing Tokens

enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Design System Preview

#Preview("Design System") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {

            // Colors
            Group {
                Text("Colors")
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)

                HStack(spacing: Spacing.sm) {
                    ColorSwatch(color: .scBackground, label: "Background\n#0F0E0C")
                    ColorSwatch(color: .scSurface,    label: "Surface\n#1A1915")
                    ColorSwatch(color: .scAccent,     label: "Accent\n#C8813A")
                    ColorSwatch(color: .scTextPrimary,label: "Text\n#F5F0E8")
                }
            }

            Divider().overlay(Color.scBorder)

            // Typography
            Group {
                Text("Typography")
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Display / Lora Bold 28").font(.scDisplay).foregroundStyle(Color.scTextPrimary)
                    Text("Headline / Lora SemiBold 22").font(.scHeadline).foregroundStyle(Color.scTextPrimary)
                    Text("Title / Lora Regular 18").font(.scTitle).foregroundStyle(Color.scTextPrimary)
                    Text("Body / SF Pro 16").font(.scBody).foregroundStyle(Color.scTextPrimary)
                    Text("Label / SF Pro Medium 14").font(.scLabel).foregroundStyle(Color.scTextSecondary)
                    Text("Caption / SF Pro 13").font(.scCaption).foregroundStyle(Color.scTextSecondary)
                }
            }

            Divider().overlay(Color.scBorder)

            // Spacing
            Group {
                Text("Spacing")
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach([
                        ("xs", Spacing.xs),
                        ("sm", Spacing.sm),
                        ("md", Spacing.md),
                        ("lg", Spacing.lg),
                        ("xl", Spacing.xl),
                        ("xxl", Spacing.xxl)
                    ], id: \.0) { name, value in
                        HStack(spacing: Spacing.sm) {
                            Rectangle()
                                .fill(Color.scAccent)
                                .frame(width: value, height: 16)
                            Text("\(name) — \(Int(value))pt")
                                .font(.scCaption)
                                .foregroundStyle(Color.scTextSecondary)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
    }
    .background(Color.scBackground)
    .preferredColorScheme(.dark)
}

private struct ColorSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.scBorder, lineWidth: 1)
                )
            Text(label)
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
        }
    }
}
