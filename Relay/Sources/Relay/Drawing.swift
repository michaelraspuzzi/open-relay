import AppKit
import CoreImage
import CryptoKit
import SwiftUI
import WebKit

// Excalidraw drawings. The Excalidraw connector's create_view draws in a host UI Relay doesn't have, so Relay
// renders the agent's elements itself: a PNG for the card (cached on disk), the live editor when opened.

enum DrawingSkeleton {
    /// Applies the tool's pseudo-elements (cameraUpdate, delete, restoreCheckpoint) and turns its
    /// startBinding/endBinding into the skeleton's start/end, giving JSON Excalidraw can convert.
    static func resolve(_ raw: String, previous: String?) -> String? {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [[String: Any]] = []
        for var item in items {
            switch item["type"] as? String {
            case "cameraUpdate":
                continue
            case "restoreCheckpoint":
                // Continue from this card's previous drawing.
                if let previous, let prior = try? JSONSerialization.jsonObject(with: Data(previous.utf8)) as? [[String: Any]] {
                    out.append(contentsOf: prior)
                }
            case "delete":
                let ids = Set((item["ids"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                out.removeAll { ids.contains($0["id"] as? String ?? "") }
            default:
                for (key, skeletonKey) in [("startBinding", "start"), ("endBinding", "end")] {
                    if let binding = item.removeValue(forKey: key) as? [String: Any], let id = binding["elementId"] as? String {
                        item[skeletonKey] = ["id": id]
                    }
                }
                out.append(item)
            }
        }
        guard !out.isEmpty, let json = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(decoding: json, as: UTF8.self)
    }
}

/// One hidden web view running Excalidraw, loaded only while drawings are being rendered.
@MainActor
final class DrawingRenderer {
    static let shared = DrawingRenderer()

    private var webView: WKWebView?
    private var ready = false
    private var idle: Task<Void, Never>?
    private var memory: [String: NSImage] = [:]
    private let cacheDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/Relay/drawings")

    static var page: URL { Assets.directory.appendingPathComponent("excalidraw.html") }

    func image(for elements: String, dark: Bool) async -> NSImage? {
        let key = SHA256.hash(data: Data((elements + (dark ? "1" : "0")).utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = memory[key] { return cached }
        let file = cacheDir.appendingPathComponent("\(key).png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory[key] = image
            return image
        }
        // Excalidraw's dark mode is a filter over the light drawing (invert + 180° hue turn); its PNG export
        // doesn't apply it, so Relay does.
        guard let base64 = await render(elements, dark: false), var png = Data(base64Encoded: base64) else { return nil }
        if dark, let inverted = Self.darkened(png) { png = inverted }
        guard let image = NSImage(data: png) else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? png.write(to: file)
        memory[key] = image
        return image
    }

    private static func darkened(_ png: Data) -> Data? {
        guard let input = CIImage(data: png) else { return nil }
        // invert(93%): x → 0.93·(1 − x) + 0.035, then hue-rotate(180°), computed in sRGB like the browser does.
        let k: CGFloat = 0.93
        let inverted = input
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: k + 0.035, y: k + 0.035, z: k + 0.035, w: 0)])
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(inverted, from: inverted.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func render(_ elements: String, dark: Bool) async -> String? {
        guard let view = await loadedView() else { return nil }
        defer { scheduleTeardown() }
        let result = try? await view.callAsyncJavaScript("return await window.relayRenderPNG(json, dark)",
                                                         arguments: ["json": elements, "dark": dark], contentWorld: .page)
        return result as? String
    }

    private func loadedView() async -> WKWebView? {
        idle?.cancel()
        if let webView, ready { return webView }
        let view = webView ?? WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if webView == nil {
            webView = view
            view.loadFileURL(Self.page, allowingReadAccessTo: Self.page.deletingLastPathComponent())
        }
        // The page imports Excalidraw from a CDN; wait (up to ~15 s) until it says it's ready.
        for _ in 0..<60 {
            if (try? await view.evaluateJavaScript("window.relayReady === true")) as? Bool == true {
                ready = true
                return view
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// Free the web view (and its ~100 MB web process) a minute after the last render.
    private func scheduleTeardown() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            webView = nil
            ready = false
        }
    }
}

/// The drawing inline in a thread.
struct DrawingBlock: View {
    let block: Block
    @Environment(\.colorScheme) private var scheme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(scheme == .dark ? Color(white: 0.07) : .white)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(8)
                    .transition(.opacity)
            } else if failed {
                Label("Couldn't render this drawing", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 300)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .task(id: (block.elements ?? "") + (scheme == .dark ? "d" : "l")) {
            guard let elements = block.elements else { failed = true; return }
            let rendered = await DrawingRenderer.shared.image(for: elements, dark: scheme == .dark)
            withAnimation(.smooth(duration: 0.3)) {
                image = rendered
                failed = rendered == nil
            }
        }
    }
}

/// The full Excalidraw editor, for an opened drawing.
struct ExcalidrawEditor: NSViewRepresentable {
    let elements: String
    let dark: Bool

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadFileURL(DrawingRenderer.page, allowingReadAccessTo: DrawingRenderer.page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(elements: elements, dark: dark) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let elements: String
        let dark: Bool
        init(elements: String, dark: Bool) { self.elements = elements; self.dark = dark }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let elements = elements, dark = dark
            Task { @MainActor in
                for _ in 0..<60 {
                    if (try? await webView.evaluateJavaScript("window.relayReady === true")) as? Bool == true { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                _ = try? await webView.callAsyncJavaScript("return window.relayOpenEditor(json, dark)",
                                                           arguments: ["json": elements, "dark": dark], contentWorld: .page)
            }
        }
    }
}

/// RELAY_DRAW_TEST=/path.png renders a sample drawing (light, then dark) to the given files and quits.
@MainActor
enum DrawingTest {
    static func runIfRequested() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["RELAY_DRAW_TEST"] else { return false }
        let sample = #"""
        [{"type":"cameraUpdate","width":800,"height":600,"x":50,"y":50},
         {"type":"rectangle","id":"b1","x":100,"y":100,"width":200,"height":100,"roundness":{"type":3},"backgroundColor":"#a5d8ff","fillStyle":"solid","label":{"text":"Relay","fontSize":20}},
         {"type":"rectangle","id":"b2","x":450,"y":100,"width":200,"height":100,"roundness":{"type":3},"backgroundColor":"#b2f2bb","fillStyle":"solid","label":{"text":"Claude","fontSize":20}},
         {"type":"arrow","id":"a1","x":300,"y":150,"width":150,"height":0,"points":[[0,0],[150,0]],"endArrowhead":"arrow","startBinding":{"elementId":"b1","fixedPoint":[1,0.5]},"endBinding":{"elementId":"b2","fixedPoint":[0,0.5]},"label":{"text":"asks","fontSize":16}},
         {"type":"rectangle","id":"gone","x":100,"y":300,"width":100,"height":50},
         {"type":"delete","ids":"gone"}]
        """#
        guard let elements = DrawingSkeleton.resolve(sample, previous: nil) else { print("DRAW: resolve failed"); exit(1) }
        for (dark, suffix) in [(false, ""), (true, "-dark")] {
            let start = Date()
            guard let image = await DrawingRenderer.shared.image(for: elements, dark: dark),
                  let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("DRAW: render failed"); exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: suffix + ".png")))
            print(String(format: "DRAW%@: %.0fx%.0f in %.1fs", suffix, image.size.width, image.size.height, -start.timeIntervalSinceNow))
        }
        fflush(stdout)
        return true
    }
}
