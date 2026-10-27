import SwiftUI

/// Zoomed out: every card as a tall mini card, the ones waiting on you first.
struct Overview: View {
    let link: MacLink
    let current: String?
    let onPick: (String?) -> Void
    let onNew: () -> Void

    var body: some View {
        let needs = link.cards.filter(\.needsYou)
        let rest = link.cards.filter { !$0.needsYou }
        VStack(spacing: 0) {
            HStack {
                Text("All cards").font(.system(size: 26, weight: .bold))
                Spacer()
                Button(action: onNew) { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40) }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("New card")
                Button { onPick(nil) } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40) }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Back to cards")
            }
            .foregroundStyle(.white)
            .padding(.leading, 24).padding(.trailing, 18).padding(.top, 4).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !needs.isEmpty {
                        section("Needs you")
                        ForEach(needs) { mini($0) }
                    }
                    if !rest.isEmpty {
                        section(needs.isEmpty ? "Your cards" : "Everything else")
                        ForEach(rest) { mini($0) }
                    }
                    if link.demo {
                        Button("Leave the demo") { link.stopDemo() }
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity).padding(.top, 16)
                    } else if let name = link.pairing?.name {
                        Menu {
                            Button("Reconnect", systemImage: "arrow.clockwise") { link.connect() }
                            Button("Forget \(name)", systemImage: "xmark.circle", role: .destructive) { link.unpair() }
                        } label: {
                            Label("Paired with \(name)", systemImage: "desktopcomputer").font(.footnote).foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 4).padding(.top, 8)
    }

    private func mini(_ card: MCard) -> some View {
        Button { onPick(card.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Logo(connector: card.connector, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name).font(.subheadline.weight(.semibold))
                        Text(card.subtitle).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusPill(card: card)
                }
                Text(lastLine(card)).font(.footnote).foregroundStyle(.white.opacity(0.82)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                if card.id == current {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Close card", systemImage: "xmark", role: .destructive) { link.close(card) } }
    }

    private func lastLine(_ card: MCard) -> String {
        if let ask = card.ask { return "Waiting for you: \(ask.detail.isEmpty ? ask.tool : ask.detail)" }
        if card.running, let activity = card.activity { return activity }
        guard let last = card.messages.last(where: { !$0.text.isEmpty || $0.block != nil }) else { return "Nothing yet" }
        if !last.text.isEmpty { return last.text }
        return last.block?.title ?? "Result"
    }
}
