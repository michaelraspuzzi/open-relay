import AppKit
import SwiftUI

/// "@calendar hold 2h for this": send a message to another card without leaving the one you're on.
/// The target card gets this card's recent conversation as context, works in the background, and its answer
/// comes back as a toast you can click.
enum Mention {
    /// What you can type after @ for each card: its id, its name without spaces, and a few short forms.
    static func handles(_ connector: Connector) -> [String] {
        let extra: [String: [String]] = [
            "code": ["claude", "cc"], "prep": ["meeting", "meetings"], "calendar": ["cal", "gcal"],
            "gmail": ["mail", "email", "inbox"], "drive": ["docs", "gdrive"], "excalidraw": ["draw", "diagram"],
            "web": ["search", "google", "lookup"], "followups": ["follow", "fu", "owe"], "linkedin": ["li", "post"],
            "crm": ["craig", "contacts", "people"], "substack": ["sub", "newsletter", "stack"],
            "memo": ["matt", "memos", "brief"],
        ]
        return [connector.id, connector.name.lowercased().replacingOccurrences(of: " ", with: "")] + (extra[connector.id] ?? [])
    }

    /// The handle a picked card is completed to, e.g. "@calendar".
    static func handle(_ connector: Connector) -> String { connector.id }

    /// Cards whose handles start with `word` (all of them for a bare "@").
    static func matches(_ word: String) -> [Connector] {
        let word = word.lowercased()
        return Connector.all.filter { connector in word.isEmpty || handles(connector).contains { $0.hasPrefix(word) } }
    }

    /// While you're still typing the card's name ("@ca", no space yet): what you've typed after @.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("@"), !draft.contains(" ") else { return nil }
        return String(draft.dropFirst())
    }

    /// "@cal hold 2h" → (Calendar, "hold 2h"). Only a leading mention routes; an exact handle beats a prefix.
    static func parse(_ text: String) -> (Connector, String)? {
        guard text.hasPrefix("@") else { return nil }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let word = parts.first.map({ String($0).lowercased() }), !word.isEmpty else { return nil }
        let exact = Connector.all.first { handles($0).contains(word) }
        guard let connector = exact ?? matches(word).first else { return nil }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (connector, rest)
    }
}

extension RelayModel {
    /// The cards listed above the composer while you type "@…".
    var mentionChoices: [Connector] {
        Mention.query(in: draft).map(Mention.matches) ?? []
    }

    /// The card a finished "@name " at the start of the composer will send to, if it isn't the focused one.
    var mentionTarget: Connector? {
        guard Mention.query(in: draft) == nil, let (target, _) = Mention.parse(draft), target.id != focused?.connector.id else { return nil }
        return target
    }

    func moveMention(_ step: Int) {
        let count = mentionChoices.count
        guard count > 0 else { return }
        mentionIndex = (mentionIndex + step + count) % count
    }

    func completeMention(_ connector: Connector? = nil) {
        let choices = mentionChoices
        guard let pick = connector ?? (choices.indices.contains(mentionIndex) ? choices[mentionIndex] : choices.first) else { return }
        draft = "@" + Mention.handle(pick) + " "
        mentionIndex = 0
    }

    /// Send `text` to a `connector` card from `source`: an idle card of that kind, or a new one beside this card.
    func route(_ text: String, to connector: Connector, from source: Card, attachments: [Attachment] = []) {
        let target = cards.first { $0.connector.id == connector.id && !$0.running && $0.ask == nil && !$0.nightShift }
            ?? newCard(connector, focus: false)
        let context = source.messages.filter { $0.note != true }.suffix(6).compactMap { message -> String? in
            let said = message.block?.plainText ?? message.text
            guard !said.isEmpty else { return nil }
            return (message.fromUser ? "me: " : "\(source.connector.name): ") + String(said.prefix(700))
        }
        var prompt = text
        if !context.isEmpty {
            prompt = "(I sent this from my \(source.connector.name) card in Relay. What we were just looking at there:\n"
                + context.joined(separator: "\n") + ")\n\n" + text
        }
        target.routedFrom = source.id
        withAnimation(.smooth) {
            target.messages.append(Message(fromUser: false, text: "From \(source.connector.name)", note: true))
            source.messages.append(Message(fromUser: false, text: "Sent to \(connector.name): \(text.prefix(60))\(text.count > 60 ? "…" : "")", note: true))
        }
        send(text, to: target, attachments: attachments, prompt: prompt)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// A card an @mention started has answered: say so where you are, and tell the card you sent it from.
    func routedFinished(_ card: Card) {
        guard let from = card.routedFrom else { return }
        card.routedFrom = nil
        let replies = card.messages.reversed().prefix { $0.fromUser == false }
        let answer = replies.first { $0.note != true && !$0.text.isEmpty }.map { Self.plain($0.text) }
            ?? replies.first { $0.block != nil }?.block.map { $0.label }
            ?? "Done"
        if let source = cards.first(where: { $0.id == from }) {
            source.pendingContext.append("my \(card.connector.name) card answered what I sent it: “\(answer.prefix(300))”")
        }
        guard card.id != focusedId else { return }
        toast(card.connector, card.connector.name, answer, target: card.id, seconds: 8)
    }
}

/// Above the composer while typing "@…": the cards you can send to. ↑ ↓ to move, Return or Tab to pick.
struct MentionList: View {
    let model: RelayModel

    var body: some View {
        let choices = model.mentionChoices
        VStack(alignment: .leading, spacing: 2) {
            Text("Send to another card").font(.rounded(11, .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, connector in
                let open = model.cards.contains { $0.connector.id == connector.id }
                Button { model.completeMention(connector) } label: {
                    HStack(spacing: 9) {
                        ConnectorIcon(connector: connector, size: 22)
                        Text(connector.name).font(.system(size: 13.5, weight: .medium))
                        Text("@" + Mention.handle(connector)).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        if connector.id == model.focused?.connector.id {
                            Text("This card").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        } else if !open {
                            Text("New card").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(index == model.mentionIndex ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 320)
        .glassCard(cornerRadius: 16)
    }
}
