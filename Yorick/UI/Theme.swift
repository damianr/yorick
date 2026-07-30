import SwiftUI

/// Yorick design system — inspired by the Sappho/SOPT visual language.
/// Monospace-forward, dark UI with subtle layered surfaces.
enum Theme {
    // MARK: - Backgrounds

    /// Base background: near-black
    static let bgPrimary = Color(red: 0.031, green: 0.031, blue: 0.043)  // #08080b
    /// Card surface: 3% white
    static let bgCard = Color.white.opacity(0.03)
    /// Elevated surface: 6% white
    static let bgElevated = Color.white.opacity(0.06)
    /// Input background: 4% white
    static let bgInput = Color.white.opacity(0.04)
    /// Hover state: 6% white
    static let bgHover = Color.white.opacity(0.06)

    // MARK: - Borders

    /// Subtle border (cards at rest)
    static let borderSubtle = Color.white.opacity(0.08)
    /// Default border (inputs, active cards)
    static let borderDefault = Color.white.opacity(0.12)
    /// Accent border (hover, focus)
    static let borderAccent = Color.white.opacity(0.15)

    // MARK: - Text

    /// Primary text: 90% white
    static let textPrimary = Color.white.opacity(0.9)
    /// Secondary text: 60% white
    static let textSecondary = Color.white.opacity(0.6)
    /// Tertiary/muted text: 35% white
    static let textTertiary = Color.white.opacity(0.35)

    // MARK: - Accents

    /// Primary accent: soft purple
    static let accentPurple = Color(red: 0.659, green: 0.608, blue: 0.910)  // #a89be8
    /// Teal accent
    static let accentTeal = Color(red: 0.314, green: 0.765, blue: 0.620)  // #50c39e
    /// Coral accent
    static let accentCoral = Color(red: 0.910, green: 0.557, blue: 0.431)  // #e88e6e
    /// Blue accent
    static let accentBlue = Color(red: 0.471, green: 0.686, blue: 0.894)  // #78afe4
    /// Amber accent
    static let accentAmber = Color(red: 0.949, green: 0.753, blue: 0.424)  // #f2c06c

    /// The marketing site's palette (index.html: --amber, --bone) — the
    /// observation pill borrows it so app and site speak one language.
    static let siteAmber = Color(red: 0.878, green: 0.706, blue: 0.345)  // #e0b458
    static let bone = Color(red: 0.925, green: 0.898, blue: 0.847)       // #ece5d8
    /// The pill's GLOW — halo and equalizer tint, pinned together (tuned in
    /// the pills playground). Warmer than bone on purpose; rim and status
    /// text stay bone, and this color never touches text.
    static let glow = Color(red: 0.847, green: 0.765, blue: 0.612)       // #d8c39c

    // MARK: - Semantic

    /// Success: soft green
    static let success = Color(red: 0.549, green: 0.824, blue: 0.471)  // #8cd278
    /// Error: soft red
    static let error = Color(red: 0.910, green: 0.471, blue: 0.431)  // #e8786e

    // MARK: - Status

    /// New item indicator
    static let statusNew = accentPurple
    /// Done indicator
    static let statusDone = success

    // MARK: - Fonts

    /// Monospace font for body text — matches Sappho's DM Mono aesthetic
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Corner Radii

    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 6
    static let radiusLg: CGFloat = 8
    static let radiusXl: CGFloat = 12
    static let radius2xl: CGFloat = 16
}

// MARK: - View Modifiers

extension View {
    /// Card style: subtle border, slight fill, rounded corners
    func cardStyle(isHovered: Bool = false, isSelected: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusLg)
                    .fill(isSelected ? Theme.bgElevated : (isHovered ? Theme.bgHover : Theme.bgCard))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLg)
                    .stroke(isHovered ? Theme.borderAccent : Theme.borderSubtle, lineWidth: 1)
            )
    }

    /// Pill button style
    func pillStyle(filled: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(filled ? Theme.accentPurple.opacity(0.15) : Theme.bgElevated)
            )
            .overlay(
                Capsule()
                    .stroke(Theme.borderSubtle, lineWidth: 1)
            )
    }
}
