//
//  Formatters.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Formatters for displaying values in the UI
enum Formatters {
    // MARK: - Number Formatters

    /// Format tokens per second
    static func tokensPerSecond(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f tok/s", value)
        } else if value >= 10 {
            return String(format: "%.1f tok/s", value)
        } else {
            return String(format: "%.2f tok/s", value)
        }
    }

    /// Format percentage (0.0 - 1.0 input)
    static func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// Format power in watts
    static func watts(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0fW", value)
        } else if value >= 10 {
            return String(format: "%.1fW", value)
        } else {
            return String(format: "%.2fW", value)
        }
    }

    /// Format bytes as human-readable size
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }

    /// Format parameter count (billions)
    static func parameters(_ billions: Double) -> String {
        if billions >= 1 {
            return String(format: "%.1fB", billions)
        } else {
            return String(format: "%.0fM", billions * 1000)
        }
    }

    /// Alias for parameters - format parameter count
    static func parameterCount(_ billions: Double) -> String {
        parameters(billions)
    }

    /// Format a generic number with thousands separators
    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Duration Formatters

    /// Format duration in seconds
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return String(format: "%dm %ds", minutes, secs)
        } else {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return String(format: "%dh %dm", hours, minutes)
        }
    }

    /// Format time to first token
    static func timeToFirstToken(_ seconds: TimeInterval) -> String {
        if seconds < 0.1 {
            return String(format: "%.0fms TTFT", seconds * 1000)
        } else {
            return String(format: "%.2fs TTFT", seconds)
        }
    }

    /// Format milliseconds
    static func milliseconds(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.2fms", ms)
        } else if ms < 10 {
            return String(format: "%.1fms", ms)
        } else if ms < 1000 {
            return String(format: "%.0fms", ms)
        } else {
            return String(format: "%.2fs", ms / 1000)
        }
    }

    // MARK: - Date Formatters

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Format date as relative (e.g., "2h ago")
    static func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Format date and time
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    // MARK: - Token Formatters

    /// Format token count
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK tokens", Double(count) / 1000)
        } else {
            return "\(count) tokens"
        }
    }

    /// Compact integer (e.g. 15708 -> "15.7K", 1_200_000 -> "1.2M").
    static func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}
