import SwiftUI

/// The bright wallpaper the glass sits on. Glass with nothing behind it is just a grey panel.
struct Wallpaper: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.62, 0.48], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.48, green: 0.80, blue: 1.00), Color(red: 0.30, green: 0.62, blue: 1.00), Color(red: 0.62, green: 0.84, blue: 1.00),
            Color(red: 0.26, green: 0.58, blue: 0.98), Color(red: 0.22, green: 0.50, blue: 0.96), Color(red: 0.36, green: 0.66, blue: 1.00),
            Color(red: 0.20, green: 0.50, blue: 0.95), Color(red: 0.45, green: 0.70, blue: 1.00), Color(red: 1.00, green: 0.80, blue: 0.62),
        ])
        .ignoresSafeArea()
    }
}

/// A connector's logo on its tile: the Mac app's PNGs, or an SF Symbol for cards without a platform logo.
struct Logo: View {
    let connector: String
    var size: CGFloat = 30
    var symbol: String? = nil

    private var image: String? {
        switch connector {
        case "code": "logo-claude"
        case "gmail", "calendar", "slack", "notion", "drive", "excalidraw": "logo-\(connector)"
        default: nil
        }
    }

    private var fallback: String {
        if let symbol, !symbol.isEmpty { return symbol }
        switch connector {
        case "ideas": return "lightbulb.max.fill"
        case "discover": return "sparkle.magnifyingglass"
        case "prep": return "person.2.wave.2.fill"
        case "web": return "globe"
        default: return "square.grid.2x2"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(connector == "code" ? Color(red: 0.97, green: 0.945, blue: 0.91) : connector == "ideas" ? Color(red: 1, green: 0.83, blue: 0.42) : .white)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(image).resizable().scaledToFit().padding(size * 0.16)
                } else {
                    Image(systemName: fallback).font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(connector == "ideas" ? Color(red: 0.35, green: 0.23, blue: 0) : .blue)
                }
            }
    }
}

/// Amber when a card needs you, pulsing blue while it works, green otherwise.
struct StatusPill: View {
    let card: MCard
    @State private var pulse = false

    var color: Color { card.needsYou ? .orange : card.running ? Color(red: 0.48, green: 0.72, blue: 1) : .green }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .opacity(card.running && pulse ? 0.3 : 1)
                .animation(card.running ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            Text(card.statusText).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.white.opacity(0.1), in: .capsule)
        .foregroundStyle(.white.opacity(0.85))
        .onAppear { pulse = true }
    }
}
