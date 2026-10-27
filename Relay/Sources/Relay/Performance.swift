import AppKit
import SwiftUI

// Keeping Relay light: every card's `claude` starts only its own connector's MCP servers, the card you land on
// warms up in the background, idle cards go to sleep (resuming by session id when you write again), the server
// list is cached instead of probed at every launch, and streamed text is applied in small batches.

/// Cards asleep after this long without activity (the focused card is kept warm while Relay is in front).
private let idleSleep: TimeInterval = ProcessInfo.processInfo.environment["RELAY_IDLE_SECONDS"].flatMap(Double.init) ?? 5 * 60
/// …and the focused one too, once Relay has been in the background this long.
private let backgroundSleep: TimeInterval = ProcessInfo.processInfo.environment["RELAY_IDLE_SECONDS"].flatMap(Double.init) ?? 10 * 60

@MainActor private var warmTask: Task<Void, Never>?
@MainActor private var pendingDeltas: [UUID: String] = [:]
@MainActor private var flushScheduled = false
@MainActor private var lastActiveApp = Date.now

extension RelayModel {
    func startPerformance() {
        let cache = ServerCache.load()
        if servers.isEmpty, let cache {
            servers = cache.items.filter { $0.status == "connected" }.map(\.name)
            serverStatus = Dictionary(cache.items.map { ($0.name, $0.status) }, uniquingKeysWith: { a, _ in a })
        }
        if let cache { bridge.send(["op": "servers", "items": cache.items.map(\.name)]) }
        // Probe (which briefly starts every server) only when the cache is missing or a day old, and not at launch.
        if cache == nil || cache!.date.timeIntervalSinceNow < -86_400 {
            Task {
                try? await Task.sleep(for: .seconds(cache == nil ? 1 : 30))
                bridge.send(["op": "probe"])
            }
        }
        // Slack channels for the draft picker: refreshed quietly once things have settled, if the saved list is a day old.
        Task {
            try? await Task.sleep(for: .seconds(45))
            if !Connector.find("slack").accounts(in: servers).isEmpty { loadSlackChannels() }
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(min(60, idleSleep / 3)))
                if NSApp.isActive { lastActiveApp = .now }
                sleepIdleCards()
            }
        }
        scheduleWarm()
    }

    /// The MCP servers a card needs; everything else is denied so it never starts. nil = all (unknown or meta cards).
    func keepServers(for card: Card) -> [String]? {
        guard !servers.isEmpty, !card.connector.isMeta else { return nil }
        if card.connector.isCode { return servers.filter { $0.lowercased().contains("vercel") } }
        // Meeting Prep starts with Calendar and Gmail; Slack, Notion and the rest stay one use_connectors away.
        let uses = card.connector.uses.flatMap { Connector.find($0).accounts(in: servers) }
        let own = card.account.map { [$0] } ?? (card.connector.accounts(in: servers) + uses)
        return (own + card.reached).uniqued()
    }

    /// The other connectors a scoped card can bring in with use_connectors, e.g. ["calendar": ["google-calendar"]].
    func reachable(from card: Card) -> [String: [String]] {
        var reach: [String: [String]] = [:]
        for other in Connector.all where !other.isMeta && !other.isCode && other.id != card.connector.id {
            let accounts = other.accounts(in: servers)
            if !accounts.isEmpty { reach[other.id] = accounts }
        }
        return reach
    }

    /// Start a card's `claude` session (resuming its conversation) if it isn't running.
    func openSession(_ card: Card) {
        guard !card.opened else { return }
        // A Codex card opens a Codex thread (its own model, tools and MCP servers); none of claude's options apply.
        if card.connector.isCodex {
            var open: [String: Any] = ["op": "open", "engine": "codex", "cardId": card.id.uuidString, "cwd": card.cwd, "system": card.systemPrompt]
            if let session = card.sessionId { open["resume"] = session }
            bridge.send(open)
            card.opened = true
            card.lastActive = .now
            return
        }
        var open: [String: Any] = [
            "op": "open", "cardId": card.id.uuidString, "cwd": card.cwd,
            "model": card.connector.model, "system": card.systemPrompt,
        ]
        // kind adds that card's own block tools (Ideas, Discover, Meeting Prep, Web, Notion's live database).
        open["kind"] = card.connector.id
        // Ideas, Discover, Meeting Prep and Web only look around (search mail, read the calendar, search the web) before they show anything.
        // Memo reads a dozen web pages per memo; asking for each one stalls it (writing the page still asks).
        if card.connector.isMeta || card.connector.isTask || card.connector.isWeb || card.connector.id == "memo" { open["autoAllowReads"] = true }
        if card.nightShift && card.connector.isCode && card.cwd.hasPrefix(Worktree.root) { open["permissionMode"] = "acceptEdits" }
        if let session = card.sessionId { open["resume"] = session }
        if card.following != nil { open["fork"] = true }
        if let keep = keepServers(for: card) { open["keep"] = keep; open["reach"] = reachable(from: card) }
        if !skillsOff.isEmpty { open["skillsOff"] = skillsOff }
        bridge.send(open)
        card.opened = true
        card.lastActive = .now
    }

    /// Warm the card you land on, after a beat so swiping past cards doesn't start them all.
    func scheduleWarm() {
        warmTask?.cancel()
        warmTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            // Without the server list a warm session would start every MCP server; wait for the probe instead.
            // A card following a desktop session waits for you to send: a warm fork would branch it for nothing.
            guard !Task.isCancelled, !servers.isEmpty, let card = focused, !card.opened, card.following == nil else { return }
            openSession(card)
        }
    }

    func sleepIdleCards() {
        let backgrounded = !NSApp.isActive && lastActiveApp.timeIntervalSinceNow < -backgroundSleep
        for card in cards where card.opened && !card.running && card.ask == nil {
            guard card.lastActive.timeIntervalSinceNow < -idleSleep, card.id != focusedId || backgrounded else { continue }
            bridge.send(["op": "close", "cardId": card.id.uuidString])
            card.opened = false
        }
    }

    // MARK: Streaming text, batched (~25 updates a second instead of one per token)

    func appendDelta(_ text: String, to card: Card) {
        pendingDeltas[card.id, default: ""] += text
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            flushDeltas()
        }
    }

    func flushDeltas() {
        flushScheduled = false
        guard !pendingDeltas.isEmpty else { return }
        let batch = pendingDeltas
        pendingDeltas = [:]
        for (id, text) in batch {
            guard let card = cards.first(where: { $0.id == id }) else { continue }
            if let last = card.messages.last, last.fromUser || last.note == true || last.block != nil {
                card.messages.append(Message(fromUser: false, text: ""))
            } else if card.messages.isEmpty {
                card.messages.append(Message(fromUser: false, text: ""))
            }
            card.messages[card.messages.count - 1].text += text
            card.activity = nil
        }
    }
}

/// The MCP server list (names and status), remembered between launches.
@MainActor
enum ServerCache {
    struct Item: Codable { var name: String; var status: String }
    struct Saved: Codable { var date: Date; var items: [Item] }

    private static let file = Store.directory.appendingPathComponent("servers.json")

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ items: [[String: Any]]) {
        let saved = Saved(date: .now, items: items.compactMap { item in
            (item["name"] as? String).map { Item(name: $0, status: item["status"] as? String ?? "unknown") }
        })
        // Probes report pending servers first; only cache a settled list.
        guard !saved.items.contains(where: { $0.status == "pending" }) else { return }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }
}
