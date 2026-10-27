import AppKit

/// Shared by reader overlays and exported PDF annotations.
public enum HighlightPalette {
    public static func color(for style: String) -> NSColor {
        let normalized = style.lowercased()
        guard normalized.utf8.count == 1, let letter = normalized.utf8.first, (97...122).contains(letter) else {
            return .systemYellow
        }
        let color: NSColor
        switch normalized {
        case "g": color = .systemGreen
        case "r": color = .systemRed
        case "b": color = .systemBlue
        case "y": color = .systemYellow
        case "o": color = .systemOrange
        case "p": color = .systemPurple
        case "k": color = .systemPink
        default:
            // Keep existing a–z types outside the named shortcuts compatible.
            let legacyColors: [NSColor] = [.systemYellow, .systemGreen, .systemBlue, .systemPink, .systemOrange, .systemPurple]
            color = legacyColors[Int(letter - 97) % legacyColors.count]
        }
        return color
    }
}
