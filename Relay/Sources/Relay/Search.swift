import AppKit
import SwiftUI

/// The Web card's answer: what you asked, what it found, and the sources it used, each opening in Relay.
/// Compact in the card (three sources); full size shows every source with what it adds.
struct SearchBlock: View {
    let block: Block
    let model: RelayModel
    var expanded = false

    private var sources: [Block.LinkItem] { block.links ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 18 : 12) {
            header
            if let answer = block.summary {
                Text(answer).font(.system(size: expanded ? 14.5 : 13)).lineSpacing(2).textSelection(.enabled)
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: expanded ? 10 : 7) {
                    HStack(spacing: 5) {
                        Text("SOURCES").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        if sources.count > 1 { Text("\(sources.count)").font(.rounded(10.5, .semibold)).foregroundStyle(.tertiary) }
                    }
                    ForEach(Array(sources.prefix(expanded ? .max : 3).enumerated()), id: \.offset) { _, source in
                        SourceRow(source: source, model: model, expanded: expanded)
                    }
                    if !expanded, sources.count > 3 {
                        Button("+\(sources.count - 3) more") { model.openBlock(block) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(expanded ? 0 : 14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ConnectorIcon(connector: Connector.find("web"), size: expanded ? 34 : 28)
            Text(block.title ?? "Web search").font(.system(size: expanded ? 18 : 14, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 4)
            if !expanded {
                Button { model.openBlock(block) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open full size")
            }
        }
    }
}

/// One source: its site's icon and name, the page title, and what it adds. Click opens it in Relay.
private struct SourceRow: View {
    let source: Block.LinkItem
    let model: RelayModel
    let expanded: Bool
    @State private var hovering = false

    private var url: URL? { URL(string: source.url) }
    private var host: String { (url?.host() ?? source.url).replacingOccurrences(of: "www.", with: "") }

    var body: some View {
        Button { model.openBlock(Block(type: "link", title: source.title, url: source.url)) } label: {
            HStack(alignment: .top, spacing: 9) {
                favicon.padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(source.title).font(.system(size: expanded ? 13.5 : 12.5, weight: .medium)).lineLimit(1)
                        Text(host).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
                    }
                    if let note = source.note {
                        Text(note).font(.system(size: expanded ? 13 : 12)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(source.url)
        .contextMenu {
            Button("Open in Browser") { if let url { NSWorkspace.shared.open(url) } }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.url, forType: .string)
            }
        }
    }

    /// The site's own favicon, straight from the site; a globe until it loads or if it has none.
    private var favicon: some View {
        AsyncImage(url: url.flatMap { URL(string: "/favicon.ico", relativeTo: $0) }) { phase in
            if let image = phase.image { image.resizable().interpolation(.high) }
            else { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(width: 16, height: 16)
        .clipShape(.rect(cornerRadius: 3.5, style: .continuous))
    }
}
