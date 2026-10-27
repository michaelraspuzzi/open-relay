import Foundation
import SwiftUI

/// A session from the Claude desktop app's Code tab, found by its title in ⌘K ("memory clean up").
struct CodeSession: Sendable {
    /// Claude Code's own session id: what its transcript is named after and what Relay resumes.
    let id: String
    let title: String
    let cwd: String
    let archived: Bool
    /// The transcript, ~/.claude/projects/<folder>/<id>.jsonl, and when it last changed.
    let transcript: String?
    let lastActivity: Date

    /// Written to in the last few minutes: probably still working in the desktop app.
    var isLive: Bool { lastActivity.timeIntervalSinceNow > -CodeSessions.liveWindow }
}

enum CodeSessions {
    static let liveWindow: TimeInterval = 3 * 60
    private static let index = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
    private static let projects = NSHomeDirectory() + "/.claude/projects"

    /// Every titled session the desktop app knows about, newest first. Reads small JSON files only.
    static func scan() -> [CodeSession] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: index) else { return [] }
        var byId: [String: CodeSession] = [:]
        for case let path as String in walker where path.hasSuffix(".json") {
            guard let data = fm.contents(atPath: index + "/" + path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["cliSessionId"] as? String, let cwd = json["cwd"] as? String else { continue }
            let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
            let transcript = transcriptPath(id, cwd: cwd)
            let indexed = (json["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let written = transcript.flatMap { modified($0) } ?? .distantPast
            let session = CodeSession(id: id, title: title, cwd: cwd, archived: json["isArchived"] as? Bool ?? false,
                                      transcript: transcript, lastActivity: max(indexed, written))
            if (byId[id]?.lastActivity ?? .distantPast) < session.lastActivity { byId[id] = session }
        }
        return byId.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Claude Code names a project's folder after its path, with every other character turned into "-".
    private static func transcriptPath(_ id: String, cwd: String) -> String? {
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let guess = "\(projects)/\(folder)/\(id).jsonl"
        if FileManager.default.fileExists(atPath: guess) { return guess }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return folders.lazy.map { "\(projects)/\($0)/\(id).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The conversation as Relay shows it: what you typed and what Claude wrote back, without tool calls,
    /// results or reminders. Reads only the end of long transcripts.
    static func messages(at path: String, limit: Int = 60) -> [Message] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 6_000_000
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if size > tail, !lines.isEmpty { lines.removeFirst() }   // probably cut mid-line
        var messages: [Message] = []
        for line in lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String, type == "user" || type == "assistant",
                  json["isMeta"] as? Bool != true, json["isSidechain"] as? Bool != true,
                  let message = json["message"] as? [String: Any] else { continue }
            let texts: [String]
            if let text = message["content"] as? String { texts = [text] }
            else if let blocks = message["content"] as? [[String: Any]] {
                texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            } else { continue }
            let text = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("[Request interrupted") }
                .joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            let fromUser = type == "user"
            // One reply often arrives as several assistant entries; show it as one bubble.
            if !fromUser, let last = messages.last, !last.fromUser {
                messages[messages.count - 1].text += "\n\n" + text
            } else {
                messages.append(Message(fromUser: fromUser, text: text))
            }
        }
        return Array(messages.suffix(limit))
    }

    static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

extension RelayModel {
    /// Shown in ⌘K while typing, under their own heading; this many at most.
    private static let sessionRows = 6

    func refreshCodeSessions() {
        Task.detached(priority: .userInitiated) {
            let sessions = CodeSessions.scan()
            await MainActor.run { [weak self] in self?.codeSessions = sessions }
        }
    }

    var codeSessionItems: [PaletteItem] {
        guard let code = Connector.all.first(where: \.isCode) else { return [] }
        return codeSessions.map { session in
            var detail = session.isLive ? "Live now" : CodeSessions.ago(session.lastActivity)
            // Sessions started without a folder run in the app's scratch space; its path means nothing to you.
            detail += " · " + (session.cwd.contains("/Claude/scratch-workspaces/") ? "no folder" : Connector.shortPath(session.cwd))
            if session.archived { detail += " · archived" }
            return PaletteItem(id: "session-\(session.id)", logo: code.logo, title: session.title, detail: detail,
                               section: .sessions, name: "Claude Code session") { [weak self] in self?.pickUp(session) }
        }
    }

    /// Keeps the best few session rows; the rest of the palette is untouched.
    func limitingSessions(_ items: [PaletteItem]) -> [PaletteItem] {
        var shown = 0
        return items.filter { item in
            guard item.section == .sessions else { return true }
            shown += 1
            return shown <= Self.sessionRows
        }
    }

    /// A desktop Claude Code session as a Relay card. It follows the transcript as the session keeps working;
    /// sending from Relay continues it as a branch (sidecar `fork`), so the desktop session is never written to.
    func pickUp(_ session: CodeSession) {
        if let card = cards.first(where: { $0.pickedUp == session.id }) { open(card); return }
        let card = newCard(Connector.find("code"), folder: session.cwd)
        card.title = session.title
        card.sessionId = session.id
        card.pickedUp = session.id
        card.following = session.transcript
        followed[card.id] = nil
        refreshFollowed(card)
        startFollowing()
    }

    /// Re-reads followed transcripts that changed, every couple of seconds, while any card follows one.
    func startFollowing() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, cards.contains(where: { $0.following != nil }) else { break }
                for card in cards where card.following != nil { refreshFollowed(card) }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.followTask = nil
        }
    }

    private func refreshFollowed(_ card: Card) {
        guard let path = card.following else { return }
        let changed = CodeSessions.modified(path) ?? .distantPast
        guard followed[card.id] != changed else { return }
        followed[card.id] = changed
        let title = card.title ?? "this session"
        Task.detached(priority: .userInitiated) {
            let messages = CodeSessions.messages(at: path)
            await MainActor.run { [weak self] in
                guard let self, card.following == path else { return }
                let live = changed.timeIntervalSinceNow > -CodeSessions.liveWindow
                let status = live ? "Live in Claude Code · updates here as “\(title)” works"
                                  : "From Claude Code · “\(title)” was last active \(CodeSessions.ago(changed))"
                withAnimation(.smooth(duration: 0.25)) {
                    card.messages = messages + [Message(fromUser: false, text: status, note: true),
                                                Message(fromUser: false, text: "Send to continue here as a copy; the original stays as it is", note: true)]
                }
                save()
            }
        }
    }

    /// Called as you send from a following card: from here on it's Relay's own branch of the session.
    func stopFollowing(_ card: Card) {
        guard card.following != nil else { return }
        card.following = nil
        followed[card.id] = nil
        // Drop the "Live in Claude Code" notes; keep one line marking where Relay took over.
        card.messages.removeAll { $0.note == true }
        card.messages.append(Message(fromUser: false, text: "Continued in Relay", note: true))
    }
}
