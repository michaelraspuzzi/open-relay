import SwiftUI

/// One screen-sized pane of glass: header, the conversation (scrolls inside), suggestions in the footer.
struct CardPane: View {
    let card: MCard
    let link: MacLink
    let typing: Bool
    let onChip: (String) -> Void
    let onNew: () -> Void
    let onHeader: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !typing {
                Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5).padding(.top, 8)
            }
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(card.messages) { message in
                        MessageRow(message: message)
                    }
                    if let ask = card.ask {
                        PermissionView(ask: ask) { decision in link.answer(card, decision) }
                            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                    }
                    if card.running, card.ask == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(card.activity ?? "Working").font(.footnote).foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(.vertical, 4)
                    }
                    if card.messages.isEmpty, card.ask == nil, !card.running {
                        Text("Ask \(card.name) anything.").font(.callout).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(14)
                .animation(.smooth(duration: 0.3), value: card.messages.count)
                .animation(.smooth(duration: 0.3), value: card.ask)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            if !typing { footer }
        }
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(.white.opacity(0.07)), in: .rect(cornerRadius: 30, style: .continuous))
        .contextMenu {
            if card.running { Button("Stop", systemImage: "stop.fill") { link.interrupt(card) } }
            Button("Close card", systemImage: "xmark", role: .destructive) { link.close(card) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Logo(connector: card.connector, size: 30, symbol: link.connectors.first { $0.id == card.connector }?.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name).font(.subheadline.weight(.semibold))
                Text(card.subtitle).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(card: card)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(.rect)
        .onTapGesture(perform: onHeader)
    }

    private var footer: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button(action: onNew) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                }
                .background(.white.opacity(0.1), in: .circle)
                .accessibilityLabel("New card")
                ForEach(card.suggestions, id: \.self) { text in
                    Button(text) { onChip(text) }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.1), in: .capsule)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.white)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5) }
    }
}

// MARK: Messages

struct MessageRow: View {
    let message: MMessage

    var body: some View {
        VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 6) {
            if message.note == true {
                Text(message.text).font(.caption).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity)
            } else if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(markdown(message.text))
                    .font(.system(size: 15))
                    .tint(.white)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(message.fromUser ? Color(red: 0.16, green: 0.48, blue: 0.96) : .white.opacity(0.1),
                                in: .rect(cornerRadius: 19, style: .continuous))
                    .frame(maxWidth: 300, alignment: message.fromUser ? .trailing : .leading)
                    .textSelection(.enabled)
            }
            if let names = message.attachments {
                ForEach(names, id: \.self) { Label($0, systemImage: "paperclip").font(.caption).foregroundStyle(.white.opacity(0.6)) }
            }
            if let block = message.block { BlockView(block: block) }
        }
        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Calendar rows, an email, a checklist, a diff: whatever the Mac flattened for us.
struct BlockView: View {
    let block: MBlock

    var body: some View {
        if block.type == "email" || block.type == "slack" {
            VStack(alignment: .leading, spacing: 4) {
                if let subtitle = block.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                if let title = block.title { Text(title).font(.subheadline.weight(.semibold)) }
                if let body = block.body { Text(body).font(.callout) }
            }
            .foregroundStyle(Color(white: 0.1))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.94), in: .rect(cornerRadius: 14, style: .continuous))
            .environment(\.colorScheme, .light)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if block.title != nil || block.subtitle != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if let title = block.title { Text(title).font(.subheadline.weight(.semibold)).lineLimit(2) }
                        Spacer(minLength: 6)
                        if let subtitle = block.subtitle {
                            Text(subtitle).font(.caption2.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.white.opacity(0.1), in: .capsule)
                        }
                    }
                }
                if let events = block.events {
                    ForEach(events, id: \.self) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Text(event.time).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5)).frame(width: 40, alignment: .leading).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.footnote.weight(.medium))
                                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.08), in: .rect(cornerRadius: 9))
                            .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9).fill(Color(red: 0.35, green: 0.66, blue: 1)).frame(width: 3) }
                        }
                    }
                }
                if let items = block.items {
                    ForEach(items, id: \.self) { item in
                        Label {
                            Text(item.text).font(.footnote).strikethrough(false)
                        } icon: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? .green : .white.opacity(0.5))
                        }
                    }
                }
                if let points = block.points {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(.white.opacity(0.5)).frame(width: 4, height: 4).offset(y: -2)
                            Text(point).font(.footnote)
                        }
                    }
                }
                if block.removed != nil || block.added != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((block.removed ?? []).enumerated()), id: \.offset) { Text("- " + $0.element).foregroundStyle(Color(red: 1, green: 0.56, blue: 0.56)) }
                        ForEach(Array((block.added ?? []).enumerated()), id: \.offset) { Text("+ " + $0.element).foregroundStyle(Color(red: 0.48, green: 0.89, blue: 0.64)) }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                }
                if let body = block.body, block.events == nil { Text(body).font(.footnote).foregroundStyle(.white.opacity(0.85)) }
                if let url = block.url, let link = URL(string: url) {
                    SwiftUI.Link(destination: link) { Label("Open", systemImage: "arrow.up.right").font(.caption.weight(.semibold)) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.18), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        }
    }
}

// MARK: Permission

/// Allow, Deny or Always allow, right in the card and in thumb reach.
struct PermissionView: View {
    let ask: MAsk
    let answer: (String) -> Void
    @State private var answered = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ask.sendLabel ?? (ask.tool == "Bash" ? "Run a command?" : "Use \(ask.tool)?")).font(.subheadline.weight(.semibold))
                Spacer()
                Text("Needs you").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.orange.opacity(0.22), in: .capsule).foregroundStyle(Color(red: 1, green: 0.82, blue: 0.54))
            }
            if !ask.detail.isEmpty {
                Text(ask.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(8)
            }
            if let block = ask.block { BlockView(block: block) }
            HStack(spacing: 8) {
                button("Deny", "deny")
                if ask.canAlways { button("Always", "always") }
                button("Allow", "allow", prominent: true)
            }
        }
        .padding(13)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.45), lineWidth: 0.5))
        .sensoryFeedback(.success, trigger: answered)
    }

    private func button(_ title: String, _ decision: String, prominent: Bool = false) -> some View {
        Button {
            answered += 1
            answer(decision)
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(prominent ? .white : .white.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                .foregroundStyle(prominent ? .black : .white)
        }
    }
}
