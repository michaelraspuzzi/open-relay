import AppKit
import SwiftUI

/// The Follow-ups card's list: who's waiting on you, what you promised, and what you're waiting on, oldest first.
/// Each row's button hands its instruction back to the card (draft the reply, the nudge, the thing you promised);
/// the circle ticks it off. Done rows fold away at the bottom.
struct FollowupsBlock: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    @State private var hovered: Int?
    @State private var showDone = false

    private var block: Block { model.draft(id) ?? Block(type: "followups") }
    private var items: [Block.FollowUp] { block.followups ?? [] }
    private var card: Card? { model.locate(id)?.0 }

    /// The three kinds, in the order they matter.
    private static let kinds: [(kind: String, title: String, action: String)] = [
        ("reply", "Waiting on you", "Draft reply"),
        ("promise", "You promised", "Do it"),
        ("waiting", "Waiting on them", "Nudge"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 18 : 12) {
            header
            ForEach(Self.kinds, id: \.kind) { kind in
                let rows = Array(items.enumerated()).filter { $0.element.kind == kind.kind && $0.element.done != true }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: expanded ? 8 : 4) {
                        Text(kind.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        ForEach(rows.prefix(expanded ? .max : 5), id: \.offset) { row($0.offset, $0.element, action: kind.action) }
                        if !expanded, rows.count > 5 {
                            Button("+\(rows.count - 5) more") { model.openBlock(block, messageId: id) }
                                .buttonStyle(.plain).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if open.isEmpty {
                Label("You're all caught up", systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
            }
            let done = Array(items.enumerated()).filter { $0.element.done == true }
            if !done.isEmpty {
                Button { withAnimation(.snappy(duration: 0.2)) { showDone.toggle() } } label: {
                    Label("\(done.count) done", systemImage: showDone ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showDone { ForEach(done, id: \.offset) { row($0.offset, $0.element, action: nil) } }
            }
        }
        .padding(expanded ? 0 : 14)
    }

    private var open: [Block.FollowUp] { items.filter { $0.done != true } }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ConnectorIcon(connector: Connector.find("followups"), size: expanded ? 32 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title ?? "Follow-ups").font(.system(size: expanded ? 18 : 14, weight: .semibold)).lineLimit(1)
                Text(open.isEmpty ? "Nothing open" : "\(open.count) open · oldest \(open.map(\.days).max() ?? 0)d")
                    .font(.system(size: expanded ? 13 : 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !expanded {
                Button { model.openBlock(block, messageId: id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open")
            }
        }
    }

    /// The row carries its own item: when the card closes, `items` empties before SwiftUI drops the old rows,
    /// so looking the item up by index here crashed (index out of range).
    private func row(_ index: Int, _ item: Block.FollowUp, action: String?) -> some View {
        let done = item.done == true
        return HStack(alignment: .center, spacing: 9) {
            Button { toggle(index) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: expanded ? 16 : 14))
                    .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain).help(done ? "Not done" : "Done")
            sourceIcon(item.source)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.who).font(.system(size: expanded ? 14 : 12.5, weight: .semibold)).lineLimit(1)
                Text(item.about).font(.system(size: expanded ? 13 : 12)).foregroundStyle(.secondary)
                    .lineLimit(expanded ? 3 : 1)
            }
            .strikethrough(done, color: .secondary)
            .opacity(done ? 0.6 : 1)
            Spacer(minLength: 6)
            if let action, !done, hovered == index || expanded {
                Button(action) { act(item) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(card?.running ?? true)
            }
            age(item.days)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(hovered == index ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -6)
        .contentShape(.rect)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .contextMenu {
            if let action, !done { Button(action) { act(item) } }
            if let url = item.link.flatMap(URL.init(string:)) { Button("Open in \(item.source == "slack" ? "Slack" : "Gmail")") { NSWorkspace.shared.open(url) } }
            Button(done ? "Mark Not Done" : "Mark Done") { toggle(index) }
        }
    }

    private func sourceIcon(_ source: String) -> some View {
        Group {
            if let logo = Assets.logo(source == "slack" ? "slack" : "gmail") {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: source == "slack" ? "number" : "envelope")
            }
        }
        .frame(width: 14, height: 14)
    }

    /// Days old, warmer the longer it's sat.
    private func age(_ days: Int) -> some View {
        let color: Color = days >= 7 ? .red : days >= 3 ? .orange : .secondary
        return Text(days == 0 ? "today" : "\(days)d").font(.rounded(11, .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }

    private func toggle(_ index: Int) {
        withAnimation(.snappy(duration: 0.2)) {
            model.editDraft(id) { block in
                guard var items = block.followups, items.indices.contains(index) else { return }
                items[index].done = !(items[index].done ?? false)
                block.followups = items
            }
        }
    }

    /// Hand the row's instruction to the card; the thread shows a short version.
    private func act(_ item: Block.FollowUp) {
        guard let card else { return }
        if expanded { model.closePage() }
        let label = switch item.kind { case "promise": "Follow through: "; case "waiting": "Nudge "; default: "Reply to " }
        model.send(label + item.who + " (" + item.about + ")", to: card,
                   prompt: item.prompt + "\n\nDraft it for me to review (show it as a draft); don't send anything.")
    }
}
