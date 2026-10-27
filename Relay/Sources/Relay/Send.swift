import AppKit
import SwiftUI

/// A send waiting out its undo window: an email or Slack draft you pressed Send on, or a send you approved for an agent.
/// Nothing leaves the Mac until the window passes; Undo (or ⌘Z) puts it back as it was.
struct HeldSend: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A draft in a card (the message id).
        case draft(UUID)
        /// An agent's send_email / slack_send_message call, approved but not yet released to it.
        case approval(card: UUID, reqId: String, decision: String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let connector: Connector
    let deadline: Date
}

extension RelayModel {
    /// The banner with Undo stays up this long; the send goes out a few seconds after it closes.
    static let bannerSeconds = 4.0
    static var undoSeconds: Double { bannerSeconds + 3 }

    func hold(_ kind: HeldSend.Kind, title: String, connector: Connector) {
        let held = HeldSend(kind: kind, title: title, connector: connector, deadline: .now + Self.undoSeconds)
        remember(held)
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { heldSends.append(held) }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        Task {
            try? await Task.sleep(for: .seconds(Self.bannerSeconds))
            guard heldSends.contains(held) else { return }
            withAnimation(.smooth(duration: 0.25)) { _ = quietHolds.insert(held.id) }
            try? await Task.sleep(for: .seconds(Self.undoSeconds - Self.bannerSeconds))
            release(held)
        }
    }

    /// Held sends still showing their notification, the only ones Undo can take back.
    var undoableSends: [HeldSend] { heldSends.filter { !quietHolds.contains($0.id) } }

    func heldSend(for draftId: UUID) -> HeldSend? {
        heldSends.first { $0.kind == .draft(draftId) }
    }

    /// The window passed (or Send now): let it go.
    func release(_ held: HeldSend) {
        guard heldSends.contains(held) else { return }
        withAnimation(.smooth(duration: 0.25)) { heldSends.removeAll { $0.id == held.id } }
        quietHolds.remove(held.id)
        // Out of Relay's hands now: kept on record until Gmail or Slack answers.
        Store.savePending(Store.loadPending().map { $0.id == held.id ? { var s = $0; s.sending = true; return s }($0) : $0 })
        switch held.kind {
        case .draft(let id):
            dispatchMail(id, action: "send")
        case .approval(let cardId, let reqId, let decision):
            bridge.send(["op": "permission", "reqId": reqId, "decision": decision])
            if let card = cards.first(where: { $0.id == cardId }) { card.activity = nil }
        }
    }

    /// Undo: the newest held send, or the one whose Undo you pressed. A draft goes back to being an editable draft;
    /// an agent's send is denied, and the agent is told you took it back.
    func undoSend(_ held: HeldSend? = nil) {
        guard let held = held ?? undoableSends.last, heldSends.contains(held) else { return }
        withAnimation(.smooth(duration: 0.25)) { heldSends.removeAll { $0.id == held.id } }
        quietHolds.remove(held.id)
        Store.savePending(Store.loadPending().filter { $0.id != held.id })
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        switch held.kind {
        case .draft:
            show("Send undone. The draft is still here", from: held.connector)
        case .approval(let cardId, let reqId, _):
            bridge.send(["op": "permission", "reqId": reqId, "decision": "deny",
                         "note": "I pressed Undo, so it was not sent. Don't retry; show it as a draft (show_email or show_slack_message) if I might still want it."])
            if let card = cards.first(where: { $0.id == cardId }) {
                card.activity = nil
                withAnimation(.smooth) { card.messages.append(Message(fromUser: false, text: "Send undone", note: true)) }
            }
            show("Send undone", from: held.connector)
        }
    }
}

// MARK: Sends that never got an answer

extension RelayModel {
    private func remember(_ held: HeldSend) {
        let cardId: UUID?, draftId: UUID?
        switch held.kind {
        case .draft(let id): (cardId, draftId) = (locate(id)?.0.id, id)
        case .approval(let card, _, _): (cardId, draftId) = (card, nil)
        }
        guard let cardId else { return }
        Store.savePending(Store.loadPending() + [Store.PendingSend(id: held.id, cardId: cardId, draftId: draftId,
                                                                   title: held.title, connectorId: held.connector.id)])
    }

    /// A draft's send got its answer (sent or failed): nothing left to report.
    func forgetPending(draft id: UUID) {
        Store.savePending(Store.loadPending().filter { $0.draftId != id })
    }

    /// An agent's sends on this card got their answer, or its turn ended without one (Relay reports what it saw).
    func forgetPending(agentSendsOn card: Card) {
        Store.savePending(Store.loadPending().filter { !($0.cardId == card.id && $0.draftId == nil) })
    }

    /// An agent's send finished: Relay says itself whether it went out, rather than leaving it to the agent's reply.
    func agentSendFinished(_ card: Card, label: String, error: String?) {
        forgetPending(agentSendsOn: card)
        if let error {
            let reason = error.replacingOccurrences(of: #"^\s*Error:\s*"#, with: "", options: .regularExpression)
            withAnimation(.smooth) { card.messages.append(Message(fromUser: false, text: "Not sent: \(reason)", note: true)) }
            show("Couldn't send — \(reason)", from: card.connector)
            if card.id != focusedId { toast(card.connector, "Not sent", label, target: card.id, seconds: 8) }
        } else {
            let done = label.replacingOccurrences(of: "Sending to", with: "Sent to")
                .replacingOccurrences(of: "Posting in", with: "Posted in").replacingOccurrences(of: "Sending", with: "Sent")
            show(done, from: card.connector)
        }
    }

    /// Sends left on record by a quit, crash or sidecar restart: say which never went out and which might have.
    /// `sidecarOnly` is the sidecar-restart case: a draft still in its undo window is fine (it goes to the new sidecar),
    /// but anything already handed over, and any agent's send (its claude is gone), is lost.
    func reportInterruptedSends(sidecarOnly: Bool = false) {
        let all = Store.loadPending()
        let lost = all.filter { !sidecarOnly || $0.sending || $0.draftId == nil }
        if sidecarOnly { heldSends.removeAll { if case .approval = $0.kind { return true }; return false } }
        guard !lost.isEmpty else { return }
        Store.savePending(all.filter { !lost.contains($0) })
        for send in lost {
            let card = cards.first { $0.id == send.cardId }
            let what = send.title.replacingOccurrences(of: "Sending to ", with: "to ").replacingOccurrences(of: "Posting in ", with: "in ")
            let (title, note): (String, String) = send.sending
                ? ("May not have sent", "Relay closed while this was going out (\(what)), so it may or may not have sent. Check Sent before trying again.")
                : ("Not sent", send.draftId == nil
                    ? "Relay closed before the send you approved (\(what)) went out. It was not sent."
                    : "Relay closed during the undo window (\(what)), so it was not sent. The draft is still here.")
            if let card {
                if let id = send.draftId, mailWork[id] != nil { mailWork[id] = nil }
                withAnimation(.smooth) { card.messages.append(Message(fromUser: false, text: note, note: true)) }
                if send.draftId == nil { card.pendingContext.append(note) }
            }
            toast(Connector.find(send.connectorId), title, what, target: card?.id, seconds: 12)
        }
        save()
    }
}

/// Top-center bar for the first few seconds of a held send: what's going where, and Undo.
struct UndoBar: View {
    let model: RelayModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.undoableSends) { held in
                UndoRow(held: held, model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct UndoRow: View {
    let held: HeldSend
    let model: RelayModel

    var body: some View {
        HStack(spacing: 10) {
            ConnectorIcon(connector: held.connector, size: 22)
            Text(held.title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: 300, alignment: .leading)
            Button { model.undoSend(held) } label: {
                Text("Undo").font(.rounded(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.accentColor.gradient, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 8)
        .glassCard(cornerRadius: 22)
    }
}

/// In a draft, while its send is held: Undo where Send was, for as long as the top notification is up; then Sending….
struct DraftUndoButton: View {
    let held: HeldSend
    let model: RelayModel

    var body: some View {
        if model.quietHolds.contains(held.id) {
            Button {} label: {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Sending…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        } else {
            Button { model.undoSend(held) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help("Undo keeps it as a draft (⌘Z)")
        }
    }
}
