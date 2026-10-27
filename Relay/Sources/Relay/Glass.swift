import AppKit
import SwiftUI

/// macOS 26 Liquid Glass (NSGlassEffectView): refracts and blurs whatever is behind the window.
struct GlassSurface: NSViewRepresentable {
    var cornerRadius: CGFloat
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = style
        view.cornerRadius = cornerRadius
    }
}

/// Full-window backdrop: softly blurs the apps and desktop behind Relay so the cards read cleanly.
struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .fullScreenUI
        view.state = .active
        view.alphaValue = 1
        view.maskImage = Self.roundedMask(windowCornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Stretchable mask that rounds the backdrop's corners to match the window.
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// Card-style glass: Liquid Glass, faint white sheen, light rim, drop shadow.
    func glassCard(cornerRadius: CGFloat, style: NSGlassEffectView.Style = .regular) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                GlassSurface(cornerRadius: cornerRadius, style: style)
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
        }
    }
}

/// Corner radius of Relay's window, close to other macOS 26 windows.
let windowCornerRadius: CGFloat = 16

/// Light rim around the window: bright along the top edge like Liquid Glass catching light, faint elsewhere.
struct WindowSheen: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
            // The bright part of the rim, fading out over the top bar; strongest a little left of centre.
            shape.strokeBorder(.white.opacity(0.75), lineWidth: 1)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.white, .white.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom).frame(height: 44)
                        Spacer(minLength: 0)
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0), .init(color: .white, location: 0.35),
                                             .init(color: .white.opacity(0.7), location: 0.7), .init(color: .white.opacity(0.45), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .allowsHitTesting(false)
    }
}

/// Drags the window when you press on it; double-click fills the screen (or puts it back).
/// Right-click offers the tiling layouts.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil); return }
            window?.performDrag(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? { WindowLayout.menu() }
    }
}

/// Half-screen and fill layouts. Menu items have no target, so they reach the app delegate through the responder chain.
enum WindowLayout {
    case left, right, fill, center

    static func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, selector) in items { menu.addItem(withTitle: title, action: selector, keyEquivalent: "") }
        return menu
    }

    static let items: [(String, Selector)] = [
        ("Fill Screen", #selector(AppDelegate.layoutFill)),
        ("Left Half", #selector(AppDelegate.layoutLeft)),
        ("Right Half", #selector(AppDelegate.layoutRight)),
        ("Center", #selector(AppDelegate.layoutCenter)),
    ]

    func frame(in visible: NSRect) -> NSRect {
        switch self {
        case .left: NSRect(x: visible.minX, y: visible.minY, width: (visible.width / 2).rounded(), height: visible.height)
        case .right: NSRect(x: visible.midX.rounded(), y: visible.minY, width: visible.maxX - visible.midX.rounded(), height: visible.height)
        case .fill: visible
        case .center:
            NSRect(x: visible.midX - visible.width * 0.35, y: visible.midY - visible.height * 0.42,
                   width: visible.width * 0.7, height: visible.height * 0.84)
        }
    }
}

/// The strip along the top of the window: traffic lights, a title, and room to grab and drag.
struct TitleBar: View {
    let model: RelayModel
    static let height: CGFloat = 40

    var body: some View {
        ZStack {
            WindowDragArea()
            Text("Relay").font(.rounded(12.5, .medium)).foregroundStyle(.secondary).allowsHitTesting(false)
            HStack {
                TrafficLights(model: model)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
        }
        .frame(height: Self.height)
        .background {
            LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).allowsHitTesting(false) }
    }
}
