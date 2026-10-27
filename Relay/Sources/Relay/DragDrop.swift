import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Font {
    /// SF Pro Rounded, for pills, chips and counts.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension UTType {
    /// A block dragged out of a card (only Relay reads it; other apps get the plain text).
    static let relayBlock = UTType(exportedAs: "org.openrelay.relay.block")
}

/// Something dropped on a card, staged in the composer until you send it.
struct Attachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// A file from Finder.
    var path: String? = nil
    /// A block dragged from a card.
    var block: Block? = nil
    /// Text dragged in from another app.
    var text: String? = nil
    /// The card a block came from, e.g. "Gmail".
    var source: String? = nil

    /// A picture Claude can look at directly (a pasted screenshot, a dropped PNG): sent as an image, shown as a thumbnail.
    var isImage: Bool {
        guard let path, block == nil else { return false }
        return Paste.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    var symbol: String {
        if let block { return block.symbol }
        if let path { return Self.fileSymbol(path) }
        return "text.quote"
    }

    private static func fileSymbol(_ path: String) -> String {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { return "folder" }
        let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .movie) == true { return "film" }
        return "doc"
    }

    /// How the receiving agent sees it.
    var promptText: String {
        if let block { return "Dropped \(block.type) from my \(source ?? "other") card:\n\(block.plainText)" }
        if isImage { return "Attached image: \(name) (included above)" }
        if let path { return "Dropped file (local path, read it with your tools): \(path)" }
        return "Dropped text:\n\(text ?? "")"
    }
}

/// Reading and writing drag payloads.
enum Drop {
    static let types: [UTType] = [.relayBlock, .fileURL, .image, .plainText]

    /// Dragging a block: Relay gets the block itself, other apps (Notes, Mail…) get its text.
    /// A generated image drags as its PNG, so Finder, Mail or another card (which sends it as a picture) get the image.
    @MainActor static func provider(for block: Block, from card: Card?) -> NSItemProvider {
        if block.type == "image", let path = block.location, let file = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) {
            file.suggestedName = block.label
            return file
        }
        let provider = NSItemProvider()
        var payload = Attachment(name: block.label, block: block, source: card?.connector.name)
        payload.id = UUID()
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.relayBlock.identifier, visibility: .ownProcess) { done in
                done(data, nil)
                return nil
            }
        }
        provider.registerObject(block.plainText as NSString, visibility: .all)
        provider.suggestedName = block.label
        return provider
    }

    static func load(_ providers: [NSItemProvider]) async -> [Attachment] {
        var out: [Attachment] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.relayBlock.identifier) {
                if let data = await data(provider, .relayBlock), let item = try? JSONDecoder().decode(Attachment.self, from: data) {
                    out.append(item)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let data = await data(provider, .fileURL), let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    out.append(Attachment(name: url.lastPathComponent, path: url.path))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // A picture dragged out of a browser or Preview, with no file behind it.
                if let data = await data(provider, .image), let image = NSImage(data: data),
                   let item = await MainActor.run(body: { Paste.attachment(for: image) }) {
                    out.append(item)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let data = await data(provider, .plainText) {
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(Attachment(name: String(text.prefix(40)), text: text)) }
                }
            }
        }
        return out
    }

    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
        }
    }
}

/// Makes a card (carousel, grid or dock) a drop target: it lights up and says what dropping will do.
struct CardDrop: ViewModifier {
    let card: Card
    let model: RelayModel
    var cornerRadius: CGFloat = 28
    var showsLabel = true
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        if showsLabel {
                            Label(card.connector.dropVerb, systemImage: "arrow.down.circle.fill")
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color.accentColor.gradient, in: .capsule)
                                .padding(.bottom, 22)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .scaleEffect(targeted ? 1.012 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.25), value: targeted)
            .onDrop(of: Drop.types, isTargeted: $targeted) { providers in
                model.drop(providers, on: card)
                return true
            }
            .onChange(of: targeted) {
                model.setDropTarget(card.id.uuidString, targeted)
                if targeted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
    }
}

extension View {
    func cardDrop(_ card: Card, model: RelayModel, cornerRadius: CGFloat = 28, showsLabel: Bool = true) -> some View {
        modifier(CardDrop(card: card, model: model, cornerRadius: cornerRadius, showsLabel: showsLabel))
    }
}

/// While something is dragged over Relay, the page dots become a dock of every card, so any card is a target.
struct DropDock: View {
    let model: RelayModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.cards) { card in DockItem(card: card, model: model) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard(cornerRadius: 22)
    }
}

private struct DockItem: View {
    let card: Card
    let model: RelayModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            ConnectorIcon(connector: card.connector, size: 36)
                .scaleEffect(targeted ? 1.35 : 1, anchor: .bottom)
            Text(card.connector.name).font(.rounded(10.5, .medium)).foregroundStyle(.secondary)
                .opacity(targeted ? 1 : 0)
        }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: targeted)
        .onDrop(of: Drop.types, isTargeted: $targeted) { providers in
            model.drop(providers, on: card)
            return true
        }
        .onChange(of: targeted) {
            model.setDropTarget("dock-" + card.id.uuidString, targeted)
            if targeted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        .help(card.connector.dropVerb)
    }
}

/// The floating chip under the pointer while dragging a block, and the staged chips in the composer.
struct DragChip: View {
    let symbol: String
    let title: String
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(title.count > 30 ? title.prefix(28) + "…" : title).font(.rounded(12, .medium)).lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10).padding(.trailing, remove == nil ? 10 : 6).padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Dropping on cards

extension RelayModel {
    /// Files, blocks or text dropped on a card: focus it, stage them in the composer, and offer the card's verb.
    func drop(_ providers: [NSItemProvider], on card: Card) {
        nonisolated(unsafe) let providers = providers
        endDrag()
        Task {
            let items = await Drop.load(providers)
            guard !items.isEmpty else { return }
            stage(items, on: card)
        }
    }

    func stage(_ items: [Attachment], on card: Card, prefill: Bool = true) {
        withAnimation(.spring(duration: 0.45, bounce: 0)) {
            focusedId = card.id
            isGrid = false
            dragOffset = 0
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) { card.staged.append(contentsOf: items) }
        if prefill, !items.allSatisfy(\.isImage), draft.trimmingCharacters(in: .whitespaces).isEmpty { draft = card.connector.dropVerb }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func unstage(_ item: Attachment, from card: Card) {
        withAnimation(.smooth(duration: 0.25)) { card.staged.removeAll { $0.id == item.id } }
        if card.staged.isEmpty && draft == card.connector.dropVerb { draft = "" }
    }

    /// Called as drop targets light up and go dark. The dock lingers briefly so moving between targets doesn't flicker.
    func setDropTarget(_ id: String, _ on: Bool) {
        if on { dropTargets.insert(id) } else { dropTargets.remove(id) }
        if on && !dragActive { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { dragActive = true } }
        guard !on else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if dropTargets.isEmpty { endDrag() }
        }
    }

    private func endDrag() {
        dropTargets = []
        if dragActive { withAnimation(.smooth(duration: 0.3)) { dragActive = false } }
    }
}
