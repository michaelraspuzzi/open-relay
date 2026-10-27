import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer takes pictures and files as well as text: ⌘V a screenshot or copied files, or drop them on a card.
/// Pictures are saved under Application Support/Relay/attachments and sent to Claude as images.
@MainActor
enum Paste {
    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif"]
    static let folder = Store.directory.appendingPathComponent("attachments")
    /// Claude takes images up to ~5 MB and gains nothing past ~2000 px on the long side.
    private static let maxSide: CGFloat = 2000
    private static let maxBytes = 3_500_000

    /// What ⌘V should stage in the composer: copied files, or a copied image (a screenshot). nil when it's text,
    /// so ordinary pasting into the text field carries on.
    static func attachments(from board: NSPasteboard = .general) -> [Attachment]? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { attachment(forFile: $0) }
        }
        guard board.availableType(from: [.string]) == nil,
              board.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil,
              let image = NSImage(pasteboard: board), let item = attachment(for: image) else { return nil }
        return [item]
    }

    /// A file from Finder; HEIC and TIFF pictures are converted so Claude can read them.
    static func attachment(forFile url: URL) -> Attachment {
        let ext = url.pathExtension.lowercased()
        if ["heic", "tiff", "tif"].contains(ext) || (["png", "jpg", "jpeg"].contains(ext) && fileSize(url) > maxBytes),
           let image = NSImage(contentsOf: url), let item = attachment(for: image, name: url.lastPathComponent) {
            return item
        }
        return Attachment(name: url.lastPathComponent, path: url.path)
    }

    /// Save a picture as PNG (or JPEG when PNG is too big), scaled down to what Claude can use.
    static func attachment(for image: NSImage, name: String? = nil) -> Attachment? {
        guard let rep = scaled(image) else { return nil }
        var data = rep.representation(using: .png, properties: [:])
        var ext = "png"
        if (data?.count ?? .max) > maxBytes {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            ext = "jpg"
        }
        guard let data else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? data.write(to: file)) != nil else { return nil }
        let label = name ?? "Screenshot \(Date.now.formatted(date: .omitted, time: .shortened))"
        return Attachment(name: label, path: file.path)
    }

    private static func scaled(_ image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, maxSide / max(width, height))
        guard scale < 1 else { return NSBitmapImageRep(cgImage: cg) }
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Thumbnails

    private static let thumbs = NSCache<NSString, NSImage>()

    static func thumbnail(_ path: String) -> NSImage? {
        if let cached = thumbs.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        thumbs.setObject(image, forKey: path as NSString)
        return image
    }
}

extension RelayModel {
    /// ⌘V in the composer: a copied screenshot or files go in as attachments. Returns false for text, which pastes as usual.
    func pasteIntoComposer() -> Bool {
        guard let card = focused, let items = Paste.attachments() else { return false }
        stage(items, on: card, prefill: false)
        return true
    }
}

/// A staged or sent picture: a rounded thumbnail; click to open it, × to remove it from the composer.
struct ImageChip: View {
    let attachment: Attachment
    var size: CGFloat = 46
    var remove: (() -> Void)? = nil

    var body: some View {
        Group {
            if let path = attachment.path, let image = Paste.thumbnail(path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.fill.tertiary)
            }
        }
        .frame(width: size * (remove == nil ? 1.6 : 1), height: size)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain).offset(x: 5, y: -5)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if let path = attachment.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
        .help(attachment.name)
    }
}
