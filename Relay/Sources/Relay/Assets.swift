import AppKit

/// Logos and the app icon: from Contents/Resources in Relay.app, or the repo's Resources/ under `swift run`.
@MainActor
enum Assets {
    static let directory: URL = {
        if let bundled = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("Logos").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
    }()

    private static var cache: [String: NSImage] = [:]

    static func logo(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        let image = NSImage(contentsOf: directory.appendingPathComponent("Logos/\(name).png"))
        cache[name] = image
        return image
    }

    /// Light or dark app icon, matching the system appearance (Auto switches to dark at sunset).
    static var appIcon: NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSImage(contentsOf: directory.appendingPathComponent(dark ? "AppIcon-Dark.png" : "AppIcon.png"))
    }
}
