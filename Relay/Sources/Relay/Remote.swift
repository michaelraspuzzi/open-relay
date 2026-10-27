import AppKit
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI

/// Relay on the iPhone talks to this: a WebSocket on the local network, advertised over Bonjour.
/// The phone is a remote for this Mac. Cards, sessions and connectors all stay here.
///
/// Phone → Mac: {t:"auth",token} first, then {t:"send",card,text} · {t:"answer",card,decision} ·
///              {t:"interrupt",card} · {t:"new",connector,folder?,worktree?,text?} · {t:"close",card}
/// Mac → phone: {t:"hello",mac,connectors,folders,order,cards} · {t:"card",card} · {t:"order",ids} · {t:"error",message}
@MainActor
final class RemoteServer {
    static let port: NWEndpoint.Port = 7788
    static let service = "_relay._tcp"

    private weak var model: RelayModel?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var sent: [UUID: String] = [:]   // last signature pushed per card
    private var sentOrder: [UUID] = []
    private var ticker: Timer?

    private final class Client: @unchecked Sendable {   // only touched on the main queue
        let connection: NWConnection
        var authed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(model: RelayModel) { self.model = model }

    // MARK: Pairing

    /// A random secret the phone has to present; scanning the pairing code hands it over.
    static let token: String = {
        let dir = Store.directory.path
        let path = dir + "/remote-token"
        if let saved = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fresh.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return fresh
    }()

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// What the pairing QR code holds; the iPhone Camera opens Relay with it.
    static var pairingURL: URL {
        var parts = URLComponents()
        parts.scheme = "relay"
        parts.host = "pair"
        let host = (ProcessInfo.processInfo.hostName as NSString).deletingPathExtension + ".local"
        parts.queryItems = [
            .init(name: "host", value: host), .init(name: "port", value: "\(port.rawValue)"),
            .init(name: "token", value: token), .init(name: "name", value: macName),
        ]
        if let tailnet = tailscaleName { parts.queryItems?.append(.init(name: "alt", value: tailnet)) }
        return parts.url!
    }

    /// This Mac's name on Tailscale, so the phone can still reach it away from home Wi-Fi (on 5G, say).
    static var tailscaleName: String? {
        let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let cli else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any], let dns = me["DNSName"] as? String, !dns.isEmpty else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }

    // MARK: Listening

    func start() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 << 20
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = true
        guard let listener = try? NWListener(using: params, on: Self.port) else { return }
        listener.service = NWListener.Service(name: Self.macName, type: Self.service)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.restart() } }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values { client.connection.cancel() }
        clients = [:]
        ticker?.invalidate()
    }

    private func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.start() } }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let key = ObjectIdentifier(connection)
        clients[key] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.drop(key) }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(client)
    }

    private func drop(_ key: ObjectIdentifier) {
        clients[key] = nil
        if !clients.values.contains(where: \.authed) { ticker?.invalidate(); ticker = nil }
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(object, from: client)
                }
                // The phone hung up: no data and nothing more coming.
                if error != nil || (data == nil && isComplete) {
                    client.connection.cancel()
                    return
                }
                if self.clients[ObjectIdentifier(client.connection)] != nil { self.receive(client) }
            }
        }
    }

    // MARK: Phone → Mac

    private func handle(_ message: [String: Any], from client: Client) {
        let type = message["t"] as? String ?? ""
        guard client.authed else {
            if type == "auth", let token = message["token"] as? String, constantTimeEqual(token, Self.token) {
                client.authed = true
                sendHello(to: client)
                startTicking()
            } else {
                write(["t": "error", "message": "This Mac doesn't recognise your phone. Pair again from Relay on the Mac."], to: client)
                client.connection.cancel()
            }
            return
        }
        guard let model else { return }
        let card = (message["card"] as? String).flatMap(UUID.init(uuidString:)).flatMap { id in model.cards.first { $0.id == id } }
        switch type {
        case "send":
            guard let card, let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if card.running {
                write(["t": "error", "message": "\(card.connector.name) is still working. Stop it or wait for it to finish."], to: client)
                return
            }
            model.send(text, to: card)
        case "answer":
            guard let card, let decision = message["decision"] as? String, ["allow", "deny", "always"].contains(decision) else { return }
            model.answer(card, decision)
        case "interrupt":
            if let card { model.interrupt(card) }
        case "close":
            if let card { model.close(card) }
        case "new":
            let connector = Connector.find(message["connector"] as? String ?? "")
            let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let folder = message["folder"] as? String
            if connector.isCode, message["worktree"] as? Bool == true {
                let repo = folder ?? Connector.defaultFolder
                let connectorId = connector.id
                Task.detached(priority: .userInitiated) { [weak self] in
                    let result = Worktree.create(from: repo)
                    await MainActor.run {
                        switch result {
                        case .success(let path): self?.startCard(Connector.find(connectorId), folder: path, text: text)
                        case .failure(let failure): self?.write(["t": "error", "message": failure.message], to: client)
                        }
                    }
                }
            } else {
                startCard(connector, folder: connector.isCode ? (folder ?? Connector.defaultFolder) : nil, text: text)
            }
        default: break
        }
    }

    private func startCard(_ connector: Connector, folder: String?, text: String) {
        guard let model else { return }
        let fresh = model.newCard(connector, folder: folder, focus: false)
        if !text.isEmpty { model.send(text, to: fresh) }
        tick()
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Mac → phone

    private func startTicking() {
        guard ticker == nil else { return }
        // Replies stream into cards in 40ms batches; ~7 pushes a second keeps the phone live without flooding it.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func sendHello(to client: Client) {
        guard let model else { return }
        let connectors = Connector.all.map { c -> [String: Any] in
            ["id": c.id, "name": c.name, "logo": c.logo, "symbol": c.symbol ?? "", "code": c.isCode]
        }
        var folders = [Connector.defaultFolder]
        for card in model.cards where card.connector.isCode {
            if let folder = card.folder, !folder.hasPrefix(Worktree.root), !folders.contains(folder) { folders.append(folder) }
        }
        write([
            "t": "hello", "mac": Self.macName, "connectors": connectors,
            "folders": folders.map { ["path": $0, "name": Connector.shortPath($0)] },
            "order": model.cards.map(\.id.uuidString),
            "cards": model.cards.map(dto),
        ], to: client)
    }

    private func tick() {
        guard let model, clients.values.contains(where: \.authed) else { return }
        // Cards first, then the order, so a new card is already known when the order places it.
        for card in model.cards {
            let signature = signature(of: card)
            guard sent[card.id] != signature else { continue }
            sent[card.id] = signature
            broadcast(["t": "card", "card": dto(card)])
        }
        let order = model.cards.map(\.id)
        if order != sentOrder {
            sentOrder = order
            broadcast(["t": "order", "ids": order.map(\.uuidString)])
            sent = sent.filter { order.contains($0.key) }
        }
    }

    private func signature(of card: Card) -> String {
        let last = card.messages.last
        return [
            "\(card.messages.count)", last?.id.uuidString ?? "", "\(last?.text.count ?? 0)", "\(last?.block?.status ?? "")",
            "\(card.running)", card.ask?.id ?? "", card.activity ?? "", card.subtitle, card.statusText,
            card.suggestions.joined(separator: "\u{1}"),
        ].joined(separator: "|")
    }

    private func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        for client in clients.values where client.authed { write(data, to: client) }
    }

    private func write(_ object: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        write(data, to: client)
    }

    private func write(_ data: Data, to client: Client) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "relay", metadata: [meta])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: What a phone sees of a card

    private func dto(_ card: Card) -> [String: Any] {
        var out: [String: Any] = [
            "id": card.id.uuidString, "connector": card.connector.id, "name": card.connector.name,
            "subtitle": card.subtitle, "status": card.ask != nil ? "needs" : card.running ? "running" : "idle",
            "statusText": card.statusText, "suggestions": card.suggestions,
            "messages": card.messages.suffix(40).map(dto),
        ]
        if let activity = card.activity { out["activity"] = activity }
        if let ask = card.ask {
            var a: [String: Any] = ["id": ask.id, "tool": ask.tool, "detail": String(ask.detail.prefix(1500)), "canAlways": ask.canAlways]
            if let label = ask.sendLabel { a["sendLabel"] = label }
            if let diff = ask.diff { a["block"] = dto(diff) }
            out["ask"] = a
        }
        return out
    }

    private func dto(_ message: Message) -> [String: Any] {
        var out: [String: Any] = ["id": message.id.uuidString, "fromUser": message.fromUser, "text": String(message.text.prefix(6000))]
        if message.note == true { out["note"] = true }
        if let block = message.block { out["block"] = dto(block) }
        if let names = message.attachments?.map(\.name), !names.isEmpty { out["attachments"] = names }
        return out
    }

    /// Blocks are rich on the Mac; the phone gets a flat summary it can draw in a few shapes.
    private func dto(_ block: Block) -> [String: Any] {
        var out: [String: Any] = ["type": block.type]
        let title = block.title ?? block.subject ?? block.file.map { ($0 as NSString).lastPathComponent } ?? block.name ?? block.channel
        if let title { out["title"] = title }
        let sub = [block.to.map { "To \($0)" }, block.from.map { "From \($0)" }, block.date, block.when, block.tag, block.status]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if !sub.isEmpty { out["subtitle"] = sub.joined(separator: " · ") }
        if let body = block.body ?? block.summary { out["body"] = String(body.prefix(1500)) }
        if let events = block.events { out["events"] = events.map { ["time": $0.time, "title": $0.title, "detail": $0.detail ?? ""] } }
        if let items = block.items { out["items"] = items.map { ["text": $0.text, "done": $0.done] } }
        if let points = block.points { out["points"] = points }
        if block.type == "diff" {
            let lines = { (s: String?) in (s ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map(String.init) }
            out["removed"] = lines(block.before)
            out["added"] = lines(block.after)
        }
        if let url = block.url { out["url"] = url }
        return out
    }
}

// MARK: Pairing window

/// "Pair iPhone…": a QR code the iPhone Camera reads; it opens Relay on the phone already paired.
struct PairView: View {
    let url = RemoteServer.pairingURL
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            if let image = qr(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(14).background(.white, in: .rect(cornerRadius: 18, style: .continuous))
            }
            Text("Pair your iPhone").font(.title3.weight(.semibold))
            Text(RemoteServer.tailscaleName == nil
                 ? "Open the Camera on your iPhone and point it at this code. Relay opens and connects to \(RemoteServer.macName) while both are on the same Wi-Fi. Install Tailscale on both to reach it from anywhere."
                 : "Open the Camera on your iPhone and point it at this code. Relay connects to \(RemoteServer.macName) on the same Wi-Fi, and through Tailscale from anywhere else.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 300)
            Button(copied ? "Copied" : "Copy pairing link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
            }
            .buttonStyle(.bordered)
            .help("For pasting into Relay on the iPhone when the Camera can't see the screen")
        }
        .padding(28)
    }

    private func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
