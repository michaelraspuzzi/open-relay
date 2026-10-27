import SwiftUI

struct ThreadView: View {
    let card: Card
    let isFocused: Bool
    let model: RelayModel

    private var waitingForText: Bool {
        card.running && card.ask == nil && (card.messages.last?.fromUser ?? true)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack on purpose. With LazyVStack, the bottom anchor and the lazy rows fed each other:
                // a scroll commit re-realised rows, the estimated height changed, that committed a new offset, and
                // SwiftUI looped inside one layout pass until the Mac ran out of memory (two hangs on 2026-10-03).
                // A thread is a few dozen bubbles, so there is nothing to be lazy about.
                VStack(spacing: 10) {
                    if card.messages.isEmpty {
                        if card.connector.isMeta { MetaEmptyCard(card: card, model: model) } else { EmptyCard(connector: card.connector) }
                    }
                    ForEach(card.messages) { message in
                        Group {
                            if let block = message.block { BlockView(block: block, model: model, card: card, messageId: message.id) }
                            else if let skill = message.skill { SkillLine(name: skill, model: model) }
                            else if message.note == true { NoteLine(text: message.text) }
                            else { Bubble(message: message) }
                        }
                        .id(message.id)
                    }
                    if let activity = card.activity, card.running { ActivityLine(text: activity) }
                    if waitingForText && card.activity == nil { TypingDots() }
                    if let ask = card.ask { ApprovalBlock(ask: ask, isFocused: isFocused) { model.answer(card, $0) } }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: card.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: card.ask) { withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

struct EmptyCard: View {
    let connector: Connector
    var body: some View {
        VStack(spacing: 10) {
            ConnectorIcon(connector: connector, size: 44)
            Text("Ask \(connector.name) anything").font(.system(size: 15, weight: .medium))
            Text("Or pick a suggestion below.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }
}

struct NoteLine: View {
    let text: String
    var body: some View {
        Text(text).font(.rounded(11.5, .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.fill.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .transition(.opacity)
    }
}

/// "Used your email-voice skill", with a switch: off hides that skill from every card until you turn it back on.
struct SkillLine: View {
    let name: String
    let model: RelayModel
    var body: some View {
        let on = !model.skillsOff.contains(name)
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
            Text(on ? "Used your \(name) skill" : "\(name) skill is off").font(.rounded(11.5, .medium))
            Text("·").foregroundStyle(.tertiary)
            Button(on ? "Turn off" : "Turn on") { withAnimation(.snappy) { model.setSkill(name, on: !on) } }
                .buttonStyle(.plain).font(.rounded(11.5, .semibold)).foregroundStyle(.tint)
                .help(on ? "Cards stop using \(name) from your next message" : "Cards use \(name) again from your next message")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.fill.quaternary, in: .capsule)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .transition(.opacity)
    }
}

struct Bubble: View {
    let message: Message
    @State private var showBrief = false

    private var rendered: AttributedString {
        var text = (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
        // On the blue bubble, links go white and underlined so they don't vanish into the accent.
        if message.fromUser {
            for run in text.runs where run.link != nil { text[run.range].underlineStyle = .single }
        }
        return text
    }

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 120) }
            VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 5) {
                if let attachments = message.attachments {
                    ForEach(attachments) { item in
                        if item.isImage { ImageChip(attachment: item, size: 110) } else { DragChip(symbol: item.symbol, title: item.name) }
                    }
                }
            Text(rendered)
                .font(.system(size: 14.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(message.fromUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .tint(message.fromUser ? .white : .accentColor)
                .background(message.fromUser ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.secondary),
                            in: .rect(cornerRadius: 18, style: .continuous))
            if let brief = message.brief { briefView(brief) }
            }
            if !message.fromUser { Spacer(minLength: 120) }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
    }
}

extension Bubble {
    /// A handed-off task: the full instructions the card was started with, under its title.
    @ViewBuilder func briefView(_ brief: String) -> some View {
        Button { withAnimation(.smooth(duration: 0.25)) { showBrief.toggle() } } label: {
            Label(showBrief ? "Hide brief" : "Full brief", systemImage: showBrief ? "chevron.up" : "text.alignleft")
                .font(.rounded(11.5, .semibold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        if showBrief {
            Text(brief)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .lineSpacing(2).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct TypingDots: View {
    var body: some View {
        HStack {
            PhaseAnimator([0, 1, 2]) { phase in
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        Circle().frame(width: 7, height: 7).opacity(phase == i ? 0.9 : 0.3)
                    }
                }
                .foregroundStyle(.secondary)
            } animation: { _ in .easeInOut(duration: 0.3) }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.fill.secondary, in: .rect(cornerRadius: 18, style: .continuous))
            Spacer()
        }
        .transition(.opacity)
    }
}

struct ActivityLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text.prefix(1).uppercased() + text.dropFirst()).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer()
        }
        .padding(.leading, 4)
        .transition(.opacity)
    }
}

struct ApprovalBlock: View {
    let ask: PermissionAsk
    let isFocused: Bool
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Allow \(ask.tool)?").font(.system(size: 13.5, weight: .semibold))
            }
            if let diff = ask.diff {
                DiffBlock(block: diff, limit: 10)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
            } else if !ask.detail.isEmpty {
                Text(ask.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack(spacing: 8) {
                button("Deny", "deny", key: .delete)
                if ask.canAlways { button("Always allow", "always", key: nil) }
                button("Allow", "allow", key: .return, prominent: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.3), lineWidth: 0.75))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    @ViewBuilder
    private func button(_ title: String, _ decision: String, key: KeyEquivalent?, prominent: Bool = false) -> some View {
        let base = Button(title) { answer(decision) }.controlSize(.regular)
        let styled = Group {
            if prominent { base.buttonStyle(.borderedProminent) } else { base.buttonStyle(.bordered) }
        }
        if isFocused, let key { styled.keyboardShortcut(key, modifiers: .command) } else { styled }
    }
}
