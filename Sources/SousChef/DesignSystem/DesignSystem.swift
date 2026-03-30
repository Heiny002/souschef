import SwiftUI

// MARK: - Color Tokens
extension Color {
    /// Near-black warm background — #0F0E0C
    static let scBackground = Color(hex: "#0F0E0C")
    /// Off-white primary text — #F5F0E8
    static let scTextPrimary = Color(hex: "#F5F0E8")
    /// Muted secondary text
    static let scTextSecondary = Color(hex: "#F5F0E8").opacity(0.6)
    /// Amber accent — #C8813A
    static let scAccent = Color(hex: "#C8813A")
    /// Subtle surface — slightly lighter than background
    static let scSurface = Color(hex: "#1A1915")
    /// Divider / border
    static let scBorder = Color(hex: "#F5F0E8").opacity(0.12)
}

private extension Color {
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
    /// Lora serif — display headings
    static let scDisplay = Font.custom("Lora-Bold", size: 28)
    static let scHeadline = Font.custom("Lora-SemiBold", size: 22)
    static let scTitle = Font.custom("Lora-Regular", size: 18)

    /// SF Pro — UI chrome
    static let scBody = Font.system(size: 16, weight: .regular, design: .default)
    static let scCaption = Font.system(size: 13, weight: .regular, design: .default)
    static let scLabel = Font.system(size: 14, weight: .medium, design: .default)
}

// MARK: - Spacing Tokens
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}
