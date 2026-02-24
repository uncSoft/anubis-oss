//
//  Theme.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI

// MARK: - Colors

extension Color {
    /// Anubis brand colors
    static let anubisAccent = Color("AccentColor")

    /// Semantic colors
    static let anubisSuccess = Color(hex: "34C759")
    static let anubisWarning = Color(hex: "FF9500")
    static let anubisError = Color(hex: "FF3B30")
    static let anubisMuted = Color(hex: "8E8E93")

    /// Chart colors
    static let chartGPU = Color(hex: "5E5CE6")
    static let chartCPU = Color(hex: "32ADE6")
    static let chartANE = Color(hex: "FF9F0A")
    static let chartMemory = Color(hex: "BF5AF2")
    static let chartTokens = Color(hex: "30D158")

    /// Per-core chart colors
    static let chartPCore = Color(hex: "5E5CE6")  // indigo (matches chartGPU family)
    static let chartECore = Color(hex: "32ADE6")   // blue (matches chartCPU family)
    static let chartGPUCore = Color(hex: "7B7BF7") // lighter indigo, distinct from CPU P-core

    /// Power & frequency chart colors
    static let chartGPUPower = Color(hex: "FF6961")
    static let chartCPUPower = Color(hex: "77B5FE")
    static let chartSystemPower = Color(hex: "960018")
    static let chartDRAMPower = Color(hex: "A8C256")
    static let chartFrequency = Color(hex: "FFD60A")
    static let chartEfficiency = Color(hex: "0ABAB5")

    // MARK: - Adaptive UI Colors

    /// Card border - subtle in dark, more visible in light
    static let cardBorder = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))

    /// Card background for layering
    static let cardBackground = Color(light: Color.white.opacity(0.8), dark: Color.white.opacity(0.05))

    /// Elevated card background
    static let cardBackgroundElevated = Color(light: Color.white, dark: Color.white.opacity(0.08))

    /// Separator lines
    static let separator = Color(light: Color.black.opacity(0.1), dark: Color.white.opacity(0.1))

    /// Subtle highlight for selected items
    static let selectionHighlight = Color(light: Color.accentColor.opacity(0.12), dark: Color.accentColor.opacity(0.25))

    /// Empty state background
    static let emptyStateBackground = Color(light: Color.black.opacity(0.03), dark: Color.white.opacity(0.03))

    /// Initialize with light/dark variants
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(dark)
            } else {
                return NSColor(light)
            }
        })
    }

    /// Initialize from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
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

// MARK: - Spacing

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}

// MARK: - Typography

extension Font {
    /// Monospace font for metrics and code
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Standard body text
    static let anubisBody = Font.system(.body)

    /// Caption text
    static let anubisCaption = Font.system(.caption)

    /// Large metric display
    static let anubisMetric = Font.system(size: 32, weight: .bold, design: .rounded)

    /// Small metric display
    static let anubisMetricSmall = Font.system(size: 20, weight: .semibold, design: .rounded)

    /// Compact metric display (for dense card layouts)
    static let anubisMetricCompact = Font.system(size: 14, weight: .semibold, design: .rounded)
}

// MARK: - View Extensions

extension View {
    /// Apply card styling with subtle border
    func cardStyle() -> some View {
        self
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(Color.cardBackgroundElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            }
    }

    /// Apply metric card styling with border
    func metricCardStyle() -> some View {
        self
            .padding(Spacing.md)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            }
    }

    /// Apply compact metric card styling (reduced padding for dense layouts)
    func compactMetricCardStyle() -> some View {
        self
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(Color.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            }
    }

    /// Apply panel styling for larger sections
    func panelStyle() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(Color.cardBackgroundElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            }
    }

    /// Apply selected item styling
    func selectedStyle(_ isSelected: Bool) -> some View {
        self
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.selectionHighlight)
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                        }
                }
            }
    }

    /// Apply subtle separator below view
    func withBottomSeparator() -> some View {
        self.overlay(alignment: .bottom) {
            Color.separator
                .frame(height: 1)
        }
    }

    /// Apply status badge styling
    func badgeStyle(color: Color) -> some View {
        self
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(color.opacity(0.15))
                    .overlay {
                        Capsule()
                            .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
                    }
            }
            .foregroundStyle(color)
    }
}

// MARK: - Animation

extension Animation {
    /// Standard spring animation
    static let anubisSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    /// Quick animation for small changes
    static let anubisQuick = Animation.easeOut(duration: 0.15)

    /// Smooth animation for transitions
    static let anubisSmooth = Animation.easeInOut(duration: 0.25)
}
