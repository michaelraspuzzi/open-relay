import Foundation

/// What the Mac sends about a card (Relay/Sources/Relay/Remote.swift builds these).
struct MCard: Identifiable, Decodable, Equatable {
    let id: String
    var connector: String
    var name: String
    var subtitle: String
    /// "needs", "running" or "idle".
    var status: String
    var statusText: String
    var suggestions: [String]
    var messages: [MMessage]
    var activity: String?
    var ask: MAsk?

    var needsYou: Bool { status == "needs" }
    var running: Bool { status == "running" }
}

struct MMessage: Identifiable, Decodable, Equatable {
    let id: String
    var fromUser: Bool
    var text: String
    var note: Bool?
    var block: MBlock?
    var attachments: [String]?
}

/// A flattened rich block: enough to draw calendars, emails, checklists and diffs on a phone.
struct MBlock: Decodable, Equatable {
    struct Event: Decodable, Equatable, Hashable { var time: String; var title: String; var detail: String }
    struct Item: Decodable, Equatable, Hashable { var text: String; var done: Bool }
    var type: String
    var title: String?
    var subtitle: String?
    var body: String?
    var events: [Event]?
    var items: [Item]?
    var points: [String]?
    var removed: [String]?
    var added: [String]?
    var url: String?
}

struct MAsk: Decodable, Equatable {
    var id: String
    var tool: String
    var detail: String
    var canAlways: Bool
    var sendLabel: String?
    var block: MBlock?
}

struct MConnector: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var logo: String
    var symbol: String
    var code: Bool
}

struct MFolder: Decodable, Hashable, Identifiable {
    var path: String
    var name: String
    var id: String { path }
}

/// Where the Mac is and the secret it handed over in the pairing code.
struct Pairing: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var name: String
    /// The Mac's Tailscale name, tried when the home-network address doesn't answer (away from Wi-Fi).
    var alt: String?

    var hosts: [String] { [host] + (alt.map { [$0] } ?? []) }

    init?(url: URL) {
        guard url.scheme == "relay", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (key: String) in items.first { $0.name == key }?.value }
        guard let host = value("host"), let token = value("token") else { return nil }
        self.host = host
        self.port = Int(value("port") ?? "") ?? 7788
        self.token = token
        self.name = value("name") ?? "your Mac"
        self.alt = value("alt")
    }

    init(host: String, port: Int, token: String, name: String) {
        self.host = host; self.port = port; self.token = token; self.name = name
    }
}

// Envelopes the Mac sends.
struct Hello: Decodable { var mac: String; var connectors: [MConnector]; var folders: [MFolder]; var order: [String]; var cards: [MCard] }
struct CardUpdate: Decodable { var card: MCard }
struct OrderUpdate: Decodable { var ids: [String] }
struct ServerError: Decodable { var message: String }
