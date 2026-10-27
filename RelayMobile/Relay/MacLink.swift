import Foundation
import Observation
import Security

/// The phone's live line to Relay on the Mac: one WebSocket, re-opened whenever the app comes back.
@Observable
final class MacLink {
    enum State: Equatable { case unpaired, connecting, connected, offline(String) }

    private(set) var state: State = .unpaired
    private(set) var pairing: Pairing?
    private(set) var macName = ""
    private(set) var cards: [MCard] = []
    private(set) var connectors: [MConnector] = []
    private(set) var folders: [MFolder] = []
    /// A short message from the Mac ("still working", "couldn't create a worktree").
    var notice: String?
    /// Sample cards instead of a Mac, for trying the app before pairing.
    private(set) var demo = false

    private var task: URLSessionWebSocketTask?
    private var attempt = 0
    private var generation = 0
    /// Which of the pairing's addresses we're on: home Wi-Fi first, then Tailscale.
    private var hostIndex = 0

    init() {
        pairing = Keychain.load()
        if pairing == nil { state = .unpaired }
    }

    // MARK: Pairing

    func pair(with url: URL) -> Bool {
        guard let fresh = Pairing(url: url) else { return false }
        pair(fresh)
        return true
    }

    func pair(_ fresh: Pairing) {
        Keychain.save(fresh)
        pairing = fresh
        demo = false
        cards = []
        hostIndex = 0
        attempt = 0
        connect()
    }

    func unpair() {
        disconnect()
        Keychain.clear()
        pairing = nil
        cards = []
        state = .unpaired
    }

    func startDemo() {
        disconnect()
        demo = true
        macName = "Demo"
        connectors = Sample.connectors
        folders = [MFolder(path: "~", name: "Home")]
        cards = Sample.cards
        state = .connected
    }

    func stopDemo() {
        demo = false
        cards = []
        state = pairing == nil ? .unpaired : .offline("Not connected")
        connect()
    }

    // MARK: Connection

    func connect() {
        guard !demo, let pairing else { return }
        disconnect()
        generation += 1
        let mine = generation
        state = .connecting
        let hosts = pairing.hosts
        let host = hosts[min(hostIndex, hosts.count - 1)]
        guard let url = URL(string: "ws://\(host):\(pairing.port)") else { state = .offline("That pairing code looks wrong."); return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 8 << 20
        self.task = task
        task.resume()
        write(["t": "auth", "token": pairing.token])
        receive(task, generation: mine)
        // A Wi-Fi-only address can hang for a minute on 5G; give each address 5 seconds to say hello.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, mine == self.generation, self.state == .connecting else { return }
            self.generation += 1
            task.cancel(with: .goingAway, reason: nil)
            self.lost()
        }
        keepAlive(task, generation: mine)
    }

    /// Cellular networks drop quiet connections; a ping every 20 seconds keeps the line open and notices when it's gone.
    private func keepAlive(_ task: URLSessionWebSocketTask, generation mine: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, mine == self.generation else { return }
            task.sendPing { error in
                guard error != nil else { return }
                Task { @MainActor in if mine == self.generation { self.generation += 1; self.lost() } }
            }
            self.keepAlive(task, generation: mine)
        }
    }

    func disconnect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Back in the foreground: reconnect right away rather than waiting out a backoff.
    func resume() {
        guard !demo, pairing != nil, state != .connected || task == nil else { return }
        if case .offline = state { state = .connecting }
        attempt = 0
        hostIndex = 0
        connect()
    }

    private func receive(_ task: URLSessionWebSocketTask, generation mine: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    self.receive(task, generation: mine)
                case .failure:
                    self.lost()
                }
            }
        }
    }

    private func lost() {
        task = nil
        // Try the next address straight away (Wi-Fi, then Tailscale) before backing off.
        if let pairing, hostIndex + 1 < pairing.hosts.count {
            hostIndex += 1
            connect()
            return
        }
        hostIndex = 0
        let name = pairing?.name ?? "your Mac"
        state = .offline(pairing?.alt == nil
            ? "Can't reach \(name). Check Relay is open and you're on the same Wi-Fi."
            : "Can't reach \(name). Check Relay is open, the Mac is awake, and Tailscale is on.")
        attempt += 1
        let delay = min(10, pow(2, Double(min(attempt, 4))) / 2)
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, mine == self.generation, !self.demo else { return }
            self.connect()
        }
    }

    private func handle(_ data: Data) {
        struct Envelope: Decodable { var t: String }
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(Envelope.self, from: data).t else { return }
        switch kind {
        case "hello":
            guard let hello = try? decoder.decode(Hello.self, from: data) else { return }
            macName = hello.mac
            connectors = hello.connectors
            folders = hello.folders
            cards = hello.order.compactMap { id in hello.cards.first { $0.id == id } }
            state = .connected
            attempt = 0
        case "card":
            guard let update = try? decoder.decode(CardUpdate.self, from: data) else { return }
            if let index = cards.firstIndex(where: { $0.id == update.card.id }) { cards[index] = update.card }
            else { cards.append(update.card) }
        case "order":
            guard let order = try? decoder.decode(OrderUpdate.self, from: data) else { return }
            let known = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            cards = order.ids.compactMap { known[$0] }
        case "error":
            if let error = try? decoder.decode(ServerError.self, from: data) {
                notice = error.message
                if state != .connected { state = .offline(error.message) }
            }
        default: break
        }
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: Actions

    func send(_ text: String, to card: MCard) {
        // Show it straight away; the Mac's copy replaces this a moment later.
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index].messages.append(MMessage(id: UUID().uuidString, fromUser: true, text: text))
            cards[index].status = "running"
            cards[index].statusText = "Working"
        }
        if demo { Sample.reply(to: card.id, in: self); return }
        write(["t": "send", "card": card.id, "text": text])
    }

    func answer(_ card: MCard, _ decision: String) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index].ask = nil
            cards[index].status = decision == "deny" ? "idle" : "running"
            cards[index].statusText = decision == "deny" ? "Ready" : "Working"
        }
        if demo { return }
        write(["t": "answer", "card": card.id, "decision": decision])
    }

    func interrupt(_ card: MCard) {
        if demo, let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index].status = "idle"; cards[index].statusText = "Ready" }
        write(["t": "interrupt", "card": card.id])
    }

    func close(_ card: MCard) {
        cards.removeAll { $0.id == card.id }
        write(["t": "close", "card": card.id])
    }

    func newCard(_ connector: MConnector, folder: String?, worktree: Bool, text: String) {
        if demo {
            cards.append(MCard(id: UUID().uuidString, connector: connector.id, name: connector.name, subtitle: connector.code ? (worktree ? "⑂ new worktree" : "Home") : "All accounts",
                               status: text.isEmpty ? "idle" : "running", statusText: text.isEmpty ? "Ready" : "Working", suggestions: [],
                               messages: text.isEmpty ? [] : [MMessage(id: UUID().uuidString, fromUser: true, text: text)]))
            return
        }
        var command: [String: Any] = ["t": "new", "connector": connector.id, "text": text, "worktree": worktree]
        if let folder { command["folder"] = folder }
        write(command)
    }

    /// Lets the sample replies land like real ones.
    func applyDemo(_ change: (inout [MCard]) -> Void) { change(&cards) }
}

// MARK: Keychain

/// The pairing secret lives in the Keychain, not in UserDefaults.
enum Keychain {
    private static let account = "relay-pairing"

    static func save(_ pairing: Pairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        clear()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> Pairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account] as CFDictionary)
    }
}
