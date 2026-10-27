import Foundation

/// Cards and their history in ~/Library/Application Support/Relay/cards.json.
/// The conversation itself lives in Claude Code's session (resumed by id); this is what the UI shows instantly.
@MainActor
enum Store {
    private struct SavedCard: Codable {
        var id: UUID
        var connectorId: String
        var sessionId: String?
        var messages: [Message]
        var suggestions: [String]
        var actionsToday: Int
        var actionsDay: String
        var account: String?
        var folder: String?
        var nightShift: Bool?
        var nightMode: Bool?
        var title: String?
        var pickedUp: String?
        var following: String?
    }

    private struct SavedState: Codable {
        var cards: [SavedCard]
        var focusedId: UUID?
    }

    /// RELAY_DATA points a test instance at its own folder so it never touches your real cards.
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELAY_DATA"] ?? NSHomeDirectory() + "/Library/Application Support/Relay")
    private static let file = directory.appendingPathComponent("cards.json")

    private static func read() -> SavedState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func load() -> [Card] {
        (read()?.cards ?? []).map { saved in
            let card = Card(connector: Connector.find(saved.connectorId), id: saved.id, sessionId: saved.sessionId, messages: saved.messages,
                 suggestions: saved.suggestions, actionsToday: saved.actionsToday, actionsDay: saved.actionsDay,
                 account: saved.account, folder: saved.folder, nightShift: saved.nightShift ?? false,
                 nightMode: saved.nightMode ?? (saved.connectorId == "ideas" && UserDefaults.standard.bool(forKey: "relay.nightMode")))
            card.title = saved.title
            card.pickedUp = saved.pickedUp
            card.following = saved.following
            return card
        }
    }

    static func loadFocus() -> UUID? { read()?.focusedId }

    static func save(_ cards: [Card], focusedId: UUID?) {
        let state = SavedState(
            cards: cards.map {
                SavedCard(id: $0.id, connectorId: $0.connector.id, sessionId: $0.sessionId, messages: $0.messages,
                          suggestions: $0.suggestions, actionsToday: $0.actionsToday, actionsDay: $0.actionsDay,
                          account: $0.account, folder: $0.folder, nightShift: $0.nightShift ? true : nil,
                          nightMode: $0.nightMode ? true : nil, title: $0.title, pickedUp: $0.pickedUp, following: $0.following)
            },
            focusedId: focusedId)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: Connector.workspace, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Sends in flight (pending.json)

    /// A send you pressed (or approved for an agent) that hasn't been confirmed yet. Written so a quit or crash during the
    /// undo window, or mid-send, can be reported on the next launch instead of vanishing.
    struct PendingSend: Codable, Equatable {
        var id: UUID
        var cardId: UUID
        /// The draft's message id; nil for an agent's send.
        var draftId: UUID?
        var title: String
        var connectorId: String
        /// Past the undo window and handed to Gmail or Slack, so it may have gone out.
        var sending = false
    }

    private static let pendingFile = directory.appendingPathComponent("pending.json")

    static func loadPending() -> [PendingSend] {
        guard let data = try? Data(contentsOf: pendingFile) else { return [] }
        return (try? JSONDecoder().decode([PendingSend].self, from: data)) ?? []
    }

    static func savePending(_ sends: [PendingSend]) {
        guard !sends.isEmpty else { try? FileManager.default.removeItem(at: pendingFile); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sends) { try? data.write(to: pendingFile, options: .atomic) }
    }

    // MARK: Night shift queue (nightshift.json)

    private static let nightFile = directory.appendingPathComponent("nightshift.json")

    static func loadNight() -> [NightTask] {
        guard let data = try? Data(contentsOf: nightFile) else { return [] }
        return (try? JSONDecoder().decode([NightTask].self, from: data)) ?? []
    }

    static func saveNight(_ queue: [NightTask]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(queue) { try? data.write(to: nightFile, options: .atomic) }
    }
}
