import AppKit
import SwiftUI

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    /// A small centered line in the thread, such as "Switched to Work".
    var note: Bool? = nil
    /// A rich block (calendar day, email, link, diff…) instead of text.
    var block: Block? = nil
    /// Files and blocks dropped on the card and sent with this message.
    var attachments: [Attachment]? = nil
    /// A handed-off task's full instructions, behind the short title its bubble shows.
    var brief: String? = nil
    /// A skill the card's claude loaded (e.g. "email-voice"), shown as a line you can turn off.
    var skill: String? = nil
}

/// One item of a Claude Code card's live task list (from its TodoWrite calls).
struct Todo: Equatable {
    var content: String
    var status: String
    var activeForm: String
}

/// Top-right notice when one card acts on another card's connector.
struct CrossToast: Identifiable, Equatable {
    let id = UUID()
    let connector: Connector
    let title: String
    let detail: String
    let target: UUID?
}

struct PermissionAsk: Identifiable, Equatable {
    let id: String
    let tool: String
    let detail: String
    let canAlways: Bool
    /// For Edit / Write: what the change would look like.
    var diff: Block? = nil
    /// The tool's full name, e.g. mcp__gmail-mcp__send_email, and for sends what the undo bar says ("Sending to lena@…").
    var rawTool = ""
    var sendLabel: String? = nil
}

/// One card: a single conversation bound to one connector (and one account or folder).
@MainActor @Observable
final class Card: Identifiable {
    let id: UUID
    let connector: Connector
    var sessionId: String?
    var messages: [Message]
    var suggestions: [String]
    var actionsToday: Int
    var actionsDay: String
    /// MCP server this card is pinned to, for connectors with several accounts.
    var account: String?
    /// Working folder, for Claude Code cards.
    var folder: String?
    /// Started by the night shift: runs unattended (code cards auto-accept edits in their worktree).
    var nightShift: Bool
    /// Ideas cards: this card suggests night-shift tasks instead of things to do now. Each Ideas card keeps its own.
    var nightMode: Bool
    /// Claude Code cards picked up from the desktop app (Sessions.swift): that session's title and id, and its
    /// transcript while the card still follows it (until you send from Relay).
    var title: String?
    var pickedUp: String?
    var following: String?

    // Live state, not saved
    var running = false
    var activity: String?
    var ask: PermissionAsk?
    /// Asks that arrived while another was on screen (parallel tool calls); each shows when the one before is answered.
    var queuedAsks: [PermissionAsk] = []
    var opened = false
    /// Last time this card's session did anything; idle cards go to sleep (see Performance.swift).
    var lastActive = Date.now
    var todos: [Todo] = []
    /// Other connectors' servers this card brought in with use_connectors; kept when it wakes from sleep.
    var reached: [String] = []
    /// What other cards did on this card's connector since it last spoke; sent along with the next message.
    var pendingContext: [String] = []
    /// Dropped files and blocks waiting in the composer for this card.
    var staged: [Attachment] = []
    /// The card an @mention sent this card's current task from; its reply comes back there as a toast.
    var routedFrom: UUID?

    init(connector: Connector, id: UUID = UUID(), sessionId: String? = nil, messages: [Message] = [],
         suggestions: [String]? = nil, actionsToday: Int = 0, actionsDay: String = Card.today,
         account: String? = nil, folder: String? = nil, nightShift: Bool = false, nightMode: Bool = false) {
        self.id = id
        self.connector = connector
        self.sessionId = sessionId
        self.messages = messages
        self.suggestions = suggestions ?? connector.starters
        self.actionsToday = actionsDay == Card.today ? actionsToday : 0
        self.actionsDay = Card.today
        self.account = account
        self.folder = folder ?? (connector.isCode ? Connector.defaultFolder : nil)
        self.nightShift = nightShift
        self.nightMode = nightMode
    }

    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    var cwd: String { folder ?? Connector.workspace }

    var subtitle: String {
        if connector.isCode {
            if let title { return title }
            if cwd.hasPrefix(Worktree.root) { return "⑂ " + (URL(fileURLWithPath: cwd).lastPathComponent) }
            return Connector.shortPath(cwd)
        }
        // Codex starts in Relay's own workspace, so a generated image or scratch file doesn't land in a repo.
        if connector.isCodex { return cwd == Connector.workspace ? "Relay workspace" : Connector.shortPath(cwd) }
        if let account { return Connector.accountName(account) }
        return "All accounts"
    }

    var systemPrompt: String {
        var prompt = Connector.shared + "\n\n" + connector.prompt
        if let agent = connector.agentInstructions { prompt += "\n\n" + agent }
        if let account {
            prompt += " Use only the tools whose names start with \(Connector.toolPrefix(account)) (the \(Connector.accountName(account)) account); ignore other \(connector.name) servers."
        }
        return prompt
    }

    var statusText: String {
        if ask != nil { return "Needs you" }
        if running { return "Working" }
        if actionsToday > 0 { return "\(actionsToday) action\(actionsToday == 1 ? "" : "s") today" }
        return "Ready"
    }

    var statusColor: Color {
        if ask != nil { return .orange }
        if running { return .blue }
        return .green
    }
}

/// One row in the ⌘K palette.
struct PaletteItem: Identifiable {
    let id: String
    let logo: String
    let title: String
    let detail: String
    /// The heading this row sits under, so "go to a card" and "make a new one" never mix.
    var section: PaletteSection = .new
    /// The card you're on right now.
    var current = false
    /// The connector this row belongs to; typing its name ranks the row first.
    var name = ""
    /// Searched but not shown: a card's whole conversation.
    var body = ""
    let action: @MainActor () -> Void

    /// How well `words` match, or nil if any word is missing. Connector name beats title beats detail,
    /// and a match at the start of a word beats one inside it.
    func score(_ words: [Substring]) -> Int? {
        let fields = [(name.lowercased(), 8), (title.lowercased(), 4), (detail.lowercased(), 1), (body.lowercased(), 1)]
        var total = 0
        for word in words {
            var best = 0
            for (text, weight) in fields where text.contains(word) {
                let atWordStart = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(word) }
                best = max(best, weight * (atWordStart ? 2 : 1) + (text.hasPrefix(word) ? 1 : 0))
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }
}

/// The palette's headings, in the order they're shown.
enum PaletteSection: Int, Comparable {
    case new, sessions, night, actions

    var title: String {
        switch self {
        case .new: "New card"
        case .sessions: "Claude Code sessions"
        case .night: "Night shift"
        case .actions: "Actions"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// All cards, the focused card, the shared composer, and the overview / palette state.
@MainActor @Observable
final class RelayModel {
    var cards: [Card] = []
    var focusedId: UUID? {
        didSet {
            guard focusedId != oldValue else { return }
            // Which way focus moved, so the composer chip turns the same way every time (← rolls down).
            let from = cards.firstIndex { $0.id == oldValue }, to = cards.firstIndex { $0.id == focusedId }
            if let from, let to { focusMovedBack = to < from }
            scheduleWarm()
        }
    }
    @ObservationIgnored var focusMovedBack = false
    var draft = ""
    /// Live horizontal trackpad drag, in points; 0 when settled.
    var dragOffset: CGFloat = 0
    /// Distance between card centers, set by the carousel.
    var stride: CGFloat = 900
    /// Pinch-out overview: every card in a 3-column grid.
    var isGrid = false
    /// Green traffic light: the focused card fills most of the screen.
    var isZoomed = false
    var paletteOpen = false { didSet { if paletteOpen && !oldValue { refreshCodeSessions() } } }
    var paletteQuery = ""
    var paletteIndex = 0
    /// The desktop app's Claude Code sessions, rescanned each time ⌘K opens (Sessions.swift).
    var codeSessions: [CodeSession] = []
    var followTask: Task<Void, Never>?
    /// When each following card last read its transcript.
    var followed: [UUID: Date] = [:]
    /// MCP servers that are connected (from the sidecar's probe).
    var servers: [String] = []
    /// Every MCP server and its status ("connected", "needs-auth", "failed"…), for the Discover card.
    var serverStatus: [String: String] = [:]
    /// The Now / Night shift mode last picked on an Ideas card; new Ideas cards start in it.
    var nightMode = UserDefaults.standard.bool(forKey: "relay.nightMode") {
        didSet { UserDefaults.standard.set(nightMode, forKey: "relay.nightMode") }
    }
    /// Night-shift ideas waiting for tonight, and the hour they start (0–23).
    var nightQueue: [NightTask] = Store.loadNight() { didSet { Store.saveNight(nightQueue); updateNightActivity() } }
    /// Skills turned off in Relay: every card's claude starts without them (see setSkill).
    var skillsOff: [String] = UserDefaults.standard.stringArray(forKey: "relay.skillsOff") ?? [] {
        didSet { UserDefaults.standard.set(skillsOff, forKey: "relay.skillsOff") }
    }
    var nightHour = UserDefaults.standard.object(forKey: "relay.nightHour") as? Int ?? 23 {
        didSet { UserDefaults.standard.set(nightHour, forKey: "relay.nightHour") }
    }
    /// Ideas already started from an Ideas card, so their buttons say so.
    var startedIdeas: Set<Block.Idea> = []
    /// Titles of ideas started in the last two weeks, as "yyyy-MM-dd title", so Ideas cards don't suggest them again.
    var ideaLog: [String] = UserDefaults.standard.stringArray(forKey: "relay.ideaLog") ?? [] {
        didSet { UserDefaults.standard.set(Array(ideaLog.suffix(60)), forKey: "relay.ideaLog") }
    }
    /// Ideas you dismissed (right-click → Dismiss), by title; hidden from Ideas cards and not suggested again.
    var dismissedIdeas: [String] = UserDefaults.standard.stringArray(forKey: "relay.dismissedIdeas") ?? [] {
        didSet { UserDefaults.standard.set(Array(dismissedIdeas.suffix(200)), forKey: "relay.dismissedIdeas") }
    }
    /// Keeps the Mac from idle-sleeping while night-shift work is queued or running.
    var nightActivity: NSObjectProtocol?
    /// Drop targets under the pointer right now; while any is, the page dots become a dock of cards.
    var dropTargets: Set<String> = []
    var dragActive = false
    var recentFolders: [String] = []
    let dictation = Dictation()
    private var dictationPrefix = ""
    var notice: String?
    /// The connector a notice is about (its logo replaces the warning icon), nil for problems.
    var noticeConnector: Connector?
    /// A block opened full size.
    var page: Block?
    /// The message holding the open page's block, when it's editable there (a to-do list).
    var pageMessage: UUID?
    var toasts: [CrossToast] = []
    /// Email drafts open full size, as tabs (message ids), and the tab showing.
    var draftTabs: [UUID] = []
    var activeDraft: UUID?
    /// A draft's text field has focus, so arrow keys and Esc belong to it.
    var editingDraft = false
    /// Drafts being saved or sent right now ("draft" / "send").
    var mailWork: [UUID: String] = [:]
    /// An email draft just saved to Gmail: asks whether to finish it in the browser page or close its card.
    var savedDraft: UUID?
    /// Your Slack channels, for a Slack draft's "In" picker. Kept between launches so the picker opens filled.
    var slackChannels: [SlackChannel] = SlackChannel.cached {
        didSet { SlackChannel.cache(slackChannels) }
    }
    var loadingChannels = false
    /// When the channel list was last fetched; it barely changes, so it's refreshed at most daily, in the background.
    private var channelsFetched = UserDefaults.standard.object(forKey: "relay.slackChannelsFetched") as? Date {
        didSet { UserDefaults.standard.set(channelsFetched, forKey: "relay.slackChannelsFetched") }
    }
    private var saveTask: Task<Void, Never>?
    var previewImages: [String: NSImage] = [:]
    /// Sends waiting out their undo window (Send.swift), newest last.
    var heldSends: [HeldSend] = []
    /// Held sends whose notification has closed; past undoing, they go out a few seconds later.
    var quietHolds: Set<UUID> = []
    /// The highlighted row in the composer's @mention list.
    var mentionIndex = 0
    /// Live Notion boards syncing or saving right now, by message id, and edits waiting on Notion (to undo on failure).
    var notionWork: [UUID: String] = [:]
    var notionEdits: [String: (message: UUID, before: Block, change: String)] = [:]

    /// Window actions, set by the app delegate.
    var onDismiss: () -> Void = {}
    var onMinimize: () -> Void = {}

    let bridge = Bridge()

    var focused: Card? { cards.first { $0.id == focusedId } }
    var focusedIndex: Int { cards.firstIndex { $0.id == focusedId } ?? 0 }

    init() {
        cards = Store.load()
        if cards.isEmpty { cards = Connector.all.map { Card(connector: $0) } }
        // Ideas and Discover arrived after the first decks were made: add them once (closing them sticks).
        if !UserDefaults.standard.bool(forKey: "relay.metaCards") {
            for id in ["ideas", "discover"] where !cards.contains(where: { $0.connector.id == id }) {
                cards.append(Card(connector: Connector.find(id)))
            }
            UserDefaults.standard.set(true, forKey: "relay.metaCards")
        }
        // Excalidraw arrived later too: add its card once, just before Claude Code.
        if !UserDefaults.standard.bool(forKey: "relay.excalidrawCard") {
            if !cards.contains(where: { $0.connector.id == "excalidraw" }) {
                let index = cards.firstIndex { $0.connector.isCode } ?? cards.count
                cards.insert(Card(connector: Connector.find("excalidraw")), at: index)
            }
            UserDefaults.standard.set(true, forKey: "relay.excalidrawCard")
        }
        // Meeting Prep arrived later too: add its card once, right after Calendar.
        if !UserDefaults.standard.bool(forKey: "relay.prepCard") {
            if !cards.contains(where: { $0.connector.isPrep }) {
                let index = cards.firstIndex { $0.connector.id == "calendar" }.map { $0 + 1 } ?? cards.count
                cards.insert(Card(connector: Connector.find("prep")), at: min(index, cards.count))
            }
            UserDefaults.standard.set(true, forKey: "relay.prepCard")
        }
        // CRM arrived later too: add its card once, right after Notion.
        if !UserDefaults.standard.bool(forKey: "relay.crmCard") {
            if !cards.contains(where: { $0.connector.id == "crm" }) {
                let index = cards.firstIndex { $0.connector.id == "notion" }.map { $0 + 1 } ?? cards.count
                cards.insert(Card(connector: Connector.find("crm")), at: min(index, cards.count))
            }
            UserDefaults.standard.set(true, forKey: "relay.crmCard")
        }
        // Web arrived later too: add its card once, right after Meeting Prep (or Calendar).
        if !UserDefaults.standard.bool(forKey: "relay.webCard") {
            if !cards.contains(where: { $0.connector.isWeb }) {
                let index = (cards.firstIndex { $0.connector.isPrep } ?? cards.firstIndex { $0.connector.id == "calendar" }).map { $0 + 1 } ?? cards.count
                cards.insert(Card(connector: Connector.find("web")), at: min(index, cards.count))
            }
            UserDefaults.standard.set(true, forKey: "relay.webCard")
        }
        // Follow-ups, LinkedIn, Memo and Substack arrived later too: add each once, after Web (or at the end).
        for id in ["followups", "linkedin", "memo", "substack"] where !UserDefaults.standard.bool(forKey: "relay.\(id)Card") {
            if !cards.contains(where: { $0.connector.id == id }) {
                let after = cards.lastIndex { ["web", "prep", "followups", "linkedin"].contains($0.connector.id) }
                cards.insert(Card(connector: Connector.find(id)), at: after.map { $0 + 1 } ?? cards.count)
            }
            UserDefaults.standard.set(true, forKey: "relay.\(id)Card")
        }
        // Codex arrived later too: add its card once, right after Claude Code.
        if !UserDefaults.standard.bool(forKey: "relay.codexCard") {
            if !cards.contains(where: { $0.connector.isCodex }) {
                let index = cards.lastIndex { $0.connector.isCode }.map { $0 + 1 } ?? cards.count
                cards.insert(Card(connector: Connector.find("codex")), at: index)
            }
            UserDefaults.standard.set(true, forKey: "relay.codexCard")
        }
        startNightClock()
        startFollowing()
        focusedId = Store.loadFocus().flatMap { id in cards.first { $0.id == id }?.id } ?? cards.first?.id
        bridge.onEvent = { [weak self] in self?.handle($0) }
        bridge.onRestart = { [weak self] in self?.sidecarRestarted() }
        // The Substack session from Relay's web view goes to the sidecar now and whenever you sign in or out.
        SubstackAccount.shared.onCookie = { [weak self] in self?.bridge.send(["op": "substackAuth", "cookie": $0]) }
        SubstackAccount.shared.start()
        // Sends a quit or crash cut off last time: say so once the window is up.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.reportInterruptedSends()
        }
        startPerformance()
        dictation.onText = { [weak self] text in
            guard let self else { return }
            draft = dictationPrefix.isEmpty ? text : dictationPrefix + " " + text
        }
        dictation.onError = { [weak self] in self?.show($0) }
        Task.detached(priority: .utility) {
            let folders = Connector.recentFolders()
            await MainActor.run { [weak self] in self?.recentFolders = folders }
        }
        // Test hook: RELAY_START=grid|palette opens in that view (RELAY_QUERY types into the palette).
        switch ProcessInfo.processInfo.environment["RELAY_START"] {
        case "grid": isGrid = true
        case "palette": paletteOpen = true
        default: break
        }
        if let query = ProcessInfo.processInfo.environment["RELAY_QUERY"] { paletteQuery = query }
        // Test hook: RELAY_DRAFT types into the composer (e.g. "@c" to see the card list).
        if let text = ProcessInfo.processInfo.environment["RELAY_DRAFT"] { draft = text }
        // Test hook: RELAY_AUTOPROMPT sends one message to the focused card and logs the reply.
        if let auto = ProcessInfo.processInfo.environment["RELAY_AUTOPROMPT"] {
            let delay = Double(ProcessInfo.processInfo.environment["RELAY_AUTOPROMPT_AFTER"] ?? "0") ?? 0
            Task {
                try? await Task.sleep(for: .seconds(delay))
                draft = auto
                submitDraft()   // same path as pressing Return
            }
        }
    }

    private let snap = Animation.spring(duration: 0.45, bounce: 0)

    // MARK: Navigation

    func move(_ step: Int) {
        guard !cards.isEmpty else { return }
        let index = focusedIndex
        let next = min(max(index + step, 0), cards.count - 1)
        withAnimation(snap) {
            focusedId = cards[next].id
            dragOffset = 0
        }
        if next != index { save() }
    }

    func jump(to index: Int) {
        guard cards.indices.contains(index) else { return }
        withAnimation(snap) {
            focusedId = cards[index].id
            dragOffset = 0
        }
    }

    func open(_ card: Card) {
        withAnimation(snap) {
            focusedId = card.id
            dragOffset = 0
            isGrid = false
            paletteOpen = false
        }
        save()
    }

    func setGrid(_ on: Bool) {
        guard on != isGrid else { return }
        withAnimation(snap) {
            isGrid = on
            dragOffset = 0
            if on { isZoomed = false }
        }
    }

    func toggleZoom() { withAnimation(snap) { isZoomed.toggle() } }

    // MARK: Trackpad drag (two-finger horizontal scroll)

    func drag(by dx: CGFloat) {
        let index = focusedIndex
        var offset = dragOffset + dx
        // Rubber-band past the first and last card.
        if (index == 0 && offset > 0) || (index == cards.count - 1 && offset < 0) { offset = dragOffset + dx * 0.3 }
        dragOffset = offset
    }

    func endDrag(velocity: CGFloat) {
        let threshold = stride * 0.18
        if dragOffset < -threshold || velocity < -8 { move(1) }
        else if dragOffset > threshold || velocity > 8 { move(-1) }
        else { move(0) }
    }

    // MARK: Cards

    /// A fresh card right after the focused one. `focus: false` leaves you where you are (an @mention's new card).
    @discardableResult
    func newCard(_ connector: Connector, account: String? = nil, folder: String? = nil, nightShift: Bool = false, focus: Bool = true) -> Card {
        let fresh = Card(connector: connector, account: account, folder: folder, nightShift: nightShift,
                         nightMode: connector.isIdeas && nightMode)
        let index = focusedIndex + 1
        withAnimation(snap) {
            cards.insert(fresh, at: min(index, cards.count))
            guard focus else { return }
            focusedId = fresh.id
            isGrid = false
            paletteOpen = false
        }
        save()
        return fresh
    }

    /// The card footer's `+`: same connector, same account or folder.
    func newCard(like card: Card) { newCard(card.connector, account: card.account, folder: card.folder) }

    func close(_ card: Card) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        bridge.send(["op": "close", "cardId": card.id.uuidString])
        withAnimation(snap) {
            cards.remove(at: index)
            toasts.removeAll { $0.target == card.id }
            if focusedId == card.id { focusedId = cards.isEmpty ? nil : cards[min(index, cards.count - 1)].id }
        }
        if cards.isEmpty { startBlank() }
        save()
    }

    /// Grid overview drag: slide a card into another slot; the rest shuffle around it.
    func moveCard(_ id: UUID, to index: Int) {
        guard let from = cards.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), cards.count - 1)
        guard to != from else { return }
        withAnimation(.snappy(duration: 0.25)) { cards.insert(cards.remove(at: from), at: to) }
    }

    func closeAll() {
        for card in cards { bridge.send(["op": "close", "cardId": card.id.uuidString]) }
        withAnimation(snap) {
            cards.removeAll()
            toasts.removeAll()
            focusedId = nil
            isGrid = false
        }
        startBlank()
        save()
    }

    /// Blank slate: nothing open, so ⌘K is the way to start.
    private func startBlank() {
        withAnimation(.snappy(duration: 0.25)) {
            paletteOpen = true
            paletteQuery = ""
            paletteIndex = 0
        }
    }

    /// A Claude Code card in its own git worktree and branch, so parallel agents don't collide.
    func newWorktreeCard(from card: Card) {
        let repo = card.cwd
        Task.detached(priority: .userInitiated) {
            let result = Worktree.create(from: repo)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let path): newCard(card.connector, folder: path)
                case .failure(let error): show(error.message)
                }
            }
        }
    }

    // MARK: Pages and previews

    func openBlock(_ block: Block, messageId: UUID? = nil) {
        if block.type == "file" || block.type == "image" {
            if let location = block.location {
                let url = location.hasPrefix("/") || location.hasPrefix("~")
                    ? URL(fileURLWithPath: (location as NSString).expandingTildeInPath) : URL(string: location)
                if let url { NSWorkspace.shared.open(url) }
            }
            return
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            page = block
            pageMessage = messageId
        }
    }

    func closePage() {
        withAnimation(.smooth(duration: 0.3)) { page = nil; pageMessage = nil }
        editingDraft = false
    }

    // MARK: Email drafts

    func locate(_ draftId: UUID) -> (Card, Int)? {
        for card in cards {
            if let index = card.messages.firstIndex(where: { $0.id == draftId }) { return (card, index) }
        }
        return nil
    }

    func draft(_ id: UUID) -> Block? { locate(id).flatMap { $0.0.messages[$0.1].block } }

    func editDraft(_ id: UUID, _ edit: (inout Block) -> Void) {
        guard let (card, index) = locate(id), var block = card.messages[index].block else { return }
        edit(&block)
        block.tag = nil   // edited since it was last saved to Gmail
        card.messages[index].block = block
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { save() }
        }
    }

    /// Every unsent draft in every card, oldest first.
    private var allDrafts: [UUID] {
        cards.flatMap { card in card.messages.filter { ["email", "slack", "invite"].contains($0.block?.type) && $0.block?.status == "draft" }.map(\.id) }
    }

    /// The expand button: open the draft full size, with the other unsent drafts as tabs beside it.
    func expandDraft(_ id: UUID) {
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            draftTabs = allDrafts
            if !draftTabs.contains(id) { draftTabs.append(id) }
            activeDraft = id
        }
    }

    /// A blank draft tab of the same kind as the one you're looking at (Slack stays Slack, Gmail stays Gmail, an invite an invite),
    /// kept in that draft's card, or in the focused card when it's the right connector.
    func newDraftTab() {
        let current = activeDraft.flatMap { locate($0) }
        let kind = current.flatMap { $0.0.messages[$0.1].block?.type }
            ?? ["slack": "slack", "calendar": "invite"][focused?.connector.id ?? ""] ?? "email"
        let slack = kind == "slack"
        let connector = ["slack": "slack", "invite": "calendar"][kind] ?? "gmail"
        let card = current?.0
            ?? (focused?.connector.id == connector ? focused : nil)
            ?? cards.first { $0.connector.id == connector }
            ?? focused
        guard let card else { return }
        let block = slack ? Block(type: "slack", status: "draft", body: "")
            : kind == "invite" ? Invite.blank()
            : Block(type: "email", status: "draft", to: "", subject: "", body: "")
        let message = Message(fromUser: false, text: "", block: block)
        card.messages.append(message)
        if slack { loadSlackChannels() }
        withAnimation(.snappy(duration: 0.25)) {
            draftTabs.append(message.id)
            activeDraft = message.id
        }
        save()
    }

    /// Throw a draft away in Relay: it leaves its card (and the tabs) without touching Gmail or Slack.
    func discardDraft(_ id: UUID) {
        guard mailWork[id] == nil, let (card, index) = locate(id) else { return }
        let block = card.messages[index].block
        closeDraftTab(id)
        withAnimation(.smooth(duration: 0.25)) { _ = card.messages.remove(at: index) }
        if let block, !((block.body ?? "").isEmpty && (block.subject ?? "").isEmpty && (block.title ?? "").isEmpty) {
            let what = block.type == "slack" ? "Slack message for \(block.channel ?? "Slack")"
                : block.type == "invite" ? "invite “\(block.title ?? "")”" : "draft “\(block.subject ?? "")”"
            card.pendingContext.append("I discarded the \(what) in Relay; don't send or save it")
        }
        if editingDraft, draftTabs.isEmpty { editingDraft = false }
        save()
    }

    /// Where a Slack draft goes, picked from your channels. A thread reply stays in its thread's channel.
    func setDraftChannel(_ id: UUID, to channel: SlackChannel) {
        editDraft(id) {
            guard $0.threadTs == nil else { return }
            $0.channel = "#" + channel.name
            $0.channelId = channel.id
        }
    }

    /// Fetch your Slack channels through the Slack account's server: on launch when the saved list is over a day old,
    /// or when you hit reload. The picker always opens on the saved list, so this never makes you wait.
    func loadSlackChannels(force: Bool = false) {
        guard !loadingChannels else { return }
        if !force, !slackChannels.isEmpty, let fetched = channelsFetched, fetched.timeIntervalSinceNow > -86_400 { return }
        let server = cards.first { $0.connector.id == "slack" }?.account
            ?? Connector.find("slack").accounts(in: servers).first ?? "plugin:slack:slack"
        loadingChannels = true
        bridge.send(["op": "channels", "prefix": Connector.toolPrefix(server)])
    }

    func closeDraftTab(_ id: UUID) {
        guard let index = draftTabs.firstIndex(of: id) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            draftTabs.remove(at: index)
            if activeDraft == id { activeDraft = draftTabs.isEmpty ? nil : draftTabs[min(index, draftTabs.count - 1)] }
        }
        if draftTabs.isEmpty { editingDraft = false; save() }
    }

    func collapseDrafts() {
        withAnimation(.smooth(duration: 0.3)) {
            draftTabs = []
            activeDraft = nil
        }
        editingDraft = false
        save()
    }

    /// Save to Gmail or Slack drafts, or send, exactly as written, through the card's account.
    /// Send waits out the undo window first (Send.swift); saving a draft goes straight away.
    func mail(_ id: UUID, action: String) {
        guard mailWork[id] == nil, heldSend(for: id) == nil, let (card, index) = locate(id), let block = card.messages[index].block else { return }
        if block.type == "slack" {
            guard let channelId = block.channelId, !channelId.isEmpty else { show("Pick a channel first"); return }
            guard !(block.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { show("Write the message first"); return }
        } else if block.type == "invite" {
            guard !(block.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { show("Give the invite a title first"); return }
            guard let start = Invite.date(block.start), let end = Invite.date(block.end) else { show("Pick a time first"); return }
            guard end > start else { show("The invite ends before it starts"); return }
        } else {
            guard !(block.to ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { show("Add a recipient first"); return }
        }
        if action == "send" {
            let title = block.type == "slack" ? "Posting in \(block.channel ?? "Slack")"
                : block.type == "invite" ? Invite.holdTitle(block) : "Sending to \(block.to ?? "")"
            hold(.draft(id), title: title, connector: card.connector)
        } else {
            dispatchMail(id, action: action)
        }
    }

    /// The actual save or send, once any undo window has passed.
    func dispatchMail(_ id: UUID, action: String) {
        guard mailWork[id] == nil, let (card, index) = locate(id), let block = card.messages[index].block else { return }
        if block.type == "slack" { return slack(id, card: card, block: block, action: action) }
        if block.type == "invite" { return invite(id, card: card, block: block) }
        let server = card.account ?? Connector.find("gmail").accounts(in: servers).first ?? "gmail-mcp"
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = action }
        var command: [String: Any] = [
            "op": "mail", "cardId": card.id.uuidString, "draftId": id.uuidString, "action": action,
            "prefix": Connector.toolPrefix(server), "to": block.to ?? "", "subject": block.subject ?? "", "body": block.body ?? "",
        ]
        command["threadId"] = block.threadId
        command["inReplyTo"] = block.inReplyTo
        bridge.send(command)
    }

    private func slack(_ id: UUID, card: Card, block: Block, action: String) {
        guard let channelId = block.channelId, !channelId.isEmpty else { show("Pick a channel first"); return }
        guard !(block.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { show("Write the message first"); return }
        let server = (card.connector.id == "slack" ? card.account : nil) ?? Connector.find("slack").accounts(in: servers).first ?? "plugin:slack:slack"
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = action }
        var command: [String: Any] = [
            "op": "slack", "cardId": card.id.uuidString, "draftId": id.uuidString, "action": action,
            "prefix": Connector.toolPrefix(server), "channelId": channelId, "body": block.body ?? "",
        ]
        command["threadTs"] = block.threadTs
        bridge.send(command)
    }

    private func invite(_ id: UUID, card: Card, block: Block) {
        let server = (card.connector.id == "calendar" ? card.account : nil)
            ?? Connector.find("calendar").accounts(in: servers).first ?? "google-calendar"
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = "send" }
        var command: [String: Any] = [
            "op": "invite", "cardId": card.id.uuidString, "draftId": id.uuidString, "prefix": Connector.toolPrefix(server),
            "title": block.title ?? "", "start": block.start ?? "", "end": block.end ?? "", "timeZone": TimeZone.current.identifier,
            "guests": block.to ?? "", "meet": block.meet ?? false,
        ]
        command["location"] = block.location.flatMap { $0.isEmpty ? nil : $0 }
        command["body"] = block.body.flatMap { $0.isEmpty ? nil : $0 }
        bridge.send(command)
    }

    private func inviteFinished(_ card: Card, _ index: Int, _ event: [String: Any]) {
        guard var block = card.messages[index].block else { return }
        let title = block.title ?? "the invite"
        guard event["ok"] as? Bool == true else {
            show("Couldn't create “\(title)” — \(event["error"] as? String ?? "unknown error")")
            return
        }
        if let url = event["url"] as? String { block.url = url }
        block.status = "created"
        block.tag = nil
        closeDraftTab(card.messages[index].id)
        let guests = Invite.guests(block.to)
        card.pendingContext.append("I created the calendar event “\(title)” (\(Invite.when(block.start, block.end) ?? "")) myself from Relay, as edited"
            + (guests.isEmpty ? "" : ", inviting \(guests.joined(separator: ", "))"))
        show(guests.isEmpty ? "Added to your calendar" : "Invited \(Invite.count(guests))", from: card.connector)
        withAnimation(.smooth(duration: 0.3)) { card.messages[index].block = block }
        save()
    }

    private func slackFinished(_ card: Card, _ index: Int, _ event: [String: Any]) {
        guard var block = card.messages[index].block else { return }
        let action = event["action"] as? String ?? ""
        let channel = block.channel ?? "Slack"
        guard event["ok"] as? Bool == true else {
            let error = event["error"] as? String ?? "unknown error"
            show(error.contains("draft_already_exists")
                 ? "\(channel) already has a Slack draft. Send or delete that one in Slack first"
                 : error.contains("not_in_channel") ? "You're not a member of \(channel)"
                 : "Couldn't \(action == "send" ? "send" : "save") — \(error)")
            return
        }
        if let url = event["url"] as? String { block.url = url }
        if action == "send" {
            block.status = "sent"
            block.tag = nil
            closeDraftTab(card.messages[index].id)
            card.pendingContext.append("I posted the Slack message in \(channel) myself from Relay, as edited")
            show("Posted in \(channel)", from: card.connector)
        } else {
            block.tag = "Saved to Slack"
            card.pendingContext.append("I saved the Slack message for \(channel) to my Slack drafts from Relay, as edited")
            show("Saved to Slack drafts", from: card.connector)
        }
        withAnimation(.smooth(duration: 0.3)) { card.messages[index].block = block }
        save()
    }

    private func mailFinished(_ card: Card, _ event: [String: Any]) {
        guard let id = (event["draftId"] as? String).flatMap(UUID.init) else { return }
        let action = event["action"] as? String ?? ""
        forgetPending(draft: id)
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = nil }
        if let index = card.messages.firstIndex(where: { $0.id == id }), card.messages[index].block?.type == "slack" {
            return slackFinished(card, index, event)
        }
        if let index = card.messages.firstIndex(where: { $0.id == id }), card.messages[index].block?.type == "invite" {
            return inviteFinished(card, index, event)
        }
        guard event["ok"] as? Bool == true else {
            show("Couldn't \(action == "send" ? "send" : "save") — \(event["error"] as? String ?? "unknown error")")
            return
        }
        guard let index = card.messages.firstIndex(where: { $0.id == id }), var block = card.messages[index].block else { return }
        let to = block.to ?? ""
        if action == "send" {
            block.status = "sent"
            block.tag = nil
            closeDraftTab(id)
            card.pendingContext.append("I sent the draft “\(block.subject ?? "")” to \(to) myself from Relay, as edited")
            show("Sent to \(to)", from: card.connector)
        } else {
            block.tag = "Saved to Gmail"
            card.pendingContext.append("I saved the draft “\(block.subject ?? "")” to my Gmail drafts from Relay, as edited")
            show("Saved to Gmail drafts", from: card.connector)
            savedDraft = id
        }
        withAnimation(.smooth(duration: 0.3)) { card.messages[index].block = block }
        save()
    }

    /// After Save draft: open Gmail's drafts in the page overlay, to finish the email there.
    func finishSavedDraftInBrowser() {
        savedDraft = nil
        collapseDrafts()
        openBlock(Block(type: "link", title: "Gmail drafts", url: "https://mail.google.com/mail/u/0/#drafts"))
    }

    /// After Save draft: the draft is safe in Gmail, so its card can go.
    func closeSavedDraftCard() {
        guard let id = savedDraft else { return }
        savedDraft = nil
        guard let (card, _) = locate(id) else { return }
        for tab in draftTabs where locate(tab)?.0.id == card.id { closeDraftTab(tab) }
        close(card)
    }

    func loadPreview(for url: String?) async {
        guard let url, previewImages[url] == nil else { return }
        if let image = await Previews.image(for: url) { previewImages[url] = image }
    }

    /// Pin a card to one account (e.g. the work Notion). Keeps the conversation; the next reply uses the new account.
    func switchAccount(_ card: Card, to account: String?) {
        guard card.account != account else { return }
        restartSession(card)
        card.account = account
        card.messages.append(Message(fromUser: false, text: "Switched to \(card.subtitle)", note: true))
        save()
    }

    /// Point a Claude Code card at another folder. That's a new project, so it starts a new conversation.
    func switchFolder(_ card: Card, to folder: String) {
        guard card.folder != folder else { return }
        restartSession(card)
        card.folder = folder
        card.sessionId = nil
        withAnimation(.smooth) {
            card.messages = [Message(fromUser: false, text: "Now in \(Connector.shortPath(folder))", note: true)]
            card.suggestions = card.connector.starters
        }
        save()
    }

    func chooseFolder(for card: Card) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: card.cwd)
        if panel.runModal() == .OK, let url = panel.url { switchFolder(card, to: url.path) }
    }

    private func restartSession(_ card: Card) {
        if card.running { interrupt(card) }
        if card.opened { bridge.send(["op": "close", "cardId": card.id.uuidString]) }
        card.opened = false
    }

    func accounts(for card: Card) -> [String] { card.connector.accounts(in: servers) }

    // MARK: ⌘K palette

    func togglePalette() {
        withAnimation(.snappy(duration: 0.25)) {
            paletteOpen.toggle()
            paletteQuery = ""
            paletteIndex = 0
        }
    }

    var paletteItems: [PaletteItem] {
        let words = paletteQuery.lowercased().split(separator: " ")
        // Cards aren't listed: you scroll between them, so ⌘K is only for making new ones.
        var items: [PaletteItem] = []
        for connector in Connector.all {
            if connector.isCode {
                for folder in ([Connector.defaultFolder] + recentFolders).uniqued() {
                    items.append(PaletteItem(id: "new-code-\(folder)", logo: connector.logo, title: "New Claude Code card",
                                             detail: "in " + Connector.shortPath(folder), section: .new, name: connector.name) { [weak self] in self?.newCard(connector, folder: folder) })
                }
                continue
            }
            let accounts = connector.accounts(in: servers)
            if accounts.count > 1 {
                for account in accounts {
                    items.append(PaletteItem(id: "new-\(connector.id)-\(account)", logo: connector.logo, title: "New \(connector.name) card",
                                             detail: Connector.accountName(account), section: .new, name: connector.name) { [weak self] in self?.newCard(connector, account: account) })
                }
            } else {
                items.append(PaletteItem(id: "new-\(connector.id)", logo: connector.logo, title: "New \(connector.name) card",
                                         detail: "Start a fresh conversation", section: .new, name: connector.name) { [weak self] in self?.newCard(connector) })
            }
        }
        items.append(PaletteItem(id: "night-ideas", logo: "night", title: "Night shift ideas",
                                 detail: "Ideas card in Night shift mode: what to hand off while you sleep",
                                 section: .night, name: "night shift ideas") { [weak self] in self?.nightShiftIdeas() })
        if !nightQueue.isEmpty {
            items.append(PaletteItem(id: "night-start", logo: "night", title: "Start the night shift now",
                                     detail: "\(nightQueue.count) queued for \(nightStartLabel)", section: .night,
                                     name: "night shift") { [weak self] in self?.startNightShift() })
        }
        if !cards.isEmpty {
            items.append(PaletteItem(id: "close-all", logo: "", title: "Close all cards", detail: "Start from a blank slate",
                                     section: .actions) { [weak self] in self?.closeAll() })
        }
        // Desktop Claude Code sessions only come up as you type ("memory", "claude code").
        if !words.isEmpty { items += codeSessionItems }
        // Stable sort by section, then by score: sections never interleave.
        return limitingSessions(items.enumerated()
            .compactMap { offset, item in (words.isEmpty ? 0 : item.score(words)).map { (offset, $0, item) } }
            .sorted { a, b in
                if a.2.section != b.2.section { return a.2.section < b.2.section }
                return a.1 != b.1 ? a.1 > b.1 : a.0 < b.0
            }
            .map(\.2))
    }

    /// Night shift from ⌘K: the Ideas card you're on (or the nearest one, or a new one), switched to Night shift.
    func nightShiftIdeas() {
        let card = focused.flatMap { $0.connector.isIdeas ? $0 : nil }
            ?? cards.first { $0.connector.isIdeas && !$0.running }
            ?? Connector.all.first { $0.isIdeas }.map { newCard($0) }
        guard let card else { return }
        nightMode = true
        card.nightMode = true
        open(card)
        send("Night shift ideas", to: card)
    }

    func movePalette(_ step: Int) {
        let count = paletteItems.count
        guard count > 0 else { return }
        paletteIndex = (paletteIndex + step + count) % count
    }

    func runPalette() {
        let items = paletteItems
        guard items.indices.contains(paletteIndex) else { return }
        items[paletteIndex].action()
        paletteOpen = false
    }

    // MARK: Conversation

    func submitDraft() {
        if dictation.isRecording { dictation.stop() }
        // Return in an open @mention list picks the highlighted card instead of sending.
        if !mentionChoices.isEmpty { completeMention(); return }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let card = focused else { return }
        // "@calendar hold 2h for this": goes to the Calendar card, with this card's conversation as context.
        if let (target, rest) = Mention.parse(text) {
            if target.id != card.connector.id {
                guard !rest.isEmpty || !card.staged.isEmpty else { return }
                draft = ""
                let attachments = card.staged
                withAnimation(.smooth(duration: 0.25)) { card.staged = [] }
                route(rest.isEmpty ? target.dropVerb : rest, to: target, from: card, attachments: attachments)
                return
            }
            text = rest
        }
        guard !card.running, !text.isEmpty || !card.staged.isEmpty else { return }
        if text.isEmpty { text = card.staged.allSatisfy(\.isImage) ? "Take a look at this" : card.connector.dropVerb }
        draft = ""
        let attachments = card.staged
        withAnimation(.smooth(duration: 0.25)) { card.staged = [] }
        send(text, to: card, attachments: attachments)
    }

    func toggleDictation() {
        if !dictation.isRecording { dictationPrefix = draft.trimmingCharacters(in: .whitespaces) }
        dictation.toggle()
    }

    /// `prompt` replaces `text` for the agent (night-shift instructions); the thread shows `text`.
    func send(_ text: String, to card: Card, attachments: [Attachment] = [], prompt hidden: String? = nil) {
        guard !card.running else { return }
        openSession(card)   // no-op when already warm (Performance.swift)
        stopFollowing(card)  // a picked-up Claude Code session is Relay's own copy from here
        withAnimation(.smooth(duration: 0.3)) {
            card.messages.append(Message(fromUser: true, text: text, attachments: attachments.isEmpty ? nil : attachments))
            card.running = true
        }
        var prompt = hidden ?? text
        if !attachments.isEmpty { prompt += "\n\n" + attachments.map(\.promptText).joined(separator: "\n\n") }
        // Task cards don't get Relay's briefing, but they do need to know when "now" is.
        if card.connector.isTask || card.connector.isWeb { prompt = "(Now: \(Date.now.formatted(date: .complete, time: .shortened)), \(TimeZone.current.identifier))\n\n" + prompt }
        if card.connector.isMeta {
            let asked = text.lowercased()
            let night = card.connector.isIdeas && (asked.contains("night") || (card.nightMode && !asked.contains("now")))
            prompt = Briefing.summary(self, night: night) + "\n\n" + prompt
        }
        if !card.pendingContext.isEmpty {
            prompt = "(For context, since we last spoke my other Relay cards did this: " + card.pendingContext.joined(separator: "; ") + ")\n\n" + prompt
            card.pendingContext = []
        }
        var command: [String: Any] = ["op": "send", "cardId": card.id.uuidString, "text": prompt]
        // Pasted screenshots and dropped pictures go to Claude as images, not as paths it would need a tool to read.
        let images = attachments.filter(\.isImage).compactMap(\.path)
        if !images.isEmpty { command["images"] = images }
        bridge.send(command)
        save()
    }

    func interrupt(_ card: Card) {
        guard card.running else { return }
        bridge.send(["op": "interrupt", "cardId": card.id.uuidString])
    }

    func answer(_ card: Card, _ decision: String) {
        guard let ask = card.ask else { return }
        withAnimation(.smooth(duration: 0.25)) { card.ask = card.queuedAsks.isEmpty ? nil : card.queuedAsks.removeFirst() }
        // Approving a send (an email, a Slack post) gets the same undo window as Relay's own Send button.
        if decision != "deny", let label = ask.sendLabel {
            card.activity = "Sending in a moment, ⌘Z to undo"
            hold(.approval(card: card.id, reqId: ask.id, decision: decision), title: label, connector: card.connector)
            return
        }
        bridge.send(["op": "permission", "reqId": ask.id, "decision": decision])
    }

    func show(_ message: String, from connector: Connector? = nil) {
        withAnimation(.smooth) {
            notice = message
            noticeConnector = connector
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.smooth) { if notice == message { notice = nil } }
        }
    }

    // MARK: Sidecar events

    private func handle(_ event: [String: Any]) {
        if event["ev"] as? String == "servers", let items = event["items"] as? [[String: Any]] {
            servers = items.filter { $0["status"] as? String == "connected" }.compactMap { $0["name"] as? String }
            serverStatus = Dictionary(items.compactMap { item in
                (item["name"] as? String).map { ($0, item["status"] as? String ?? "unknown") }
            }, uniquingKeysWith: { a, _ in a })
            ServerCache.save(items)
            scheduleWarm()
            return
        }
        if event["ev"] as? String == "notion" { return notionFinished(event) }
        if event["ev"] as? String == "substackAccount" { return substackAccount(event) }
        if event["ev"] as? String == "channels" {
            loadingChannels = false
            let items = (event["items"] as? [[String: Any]] ?? []).compactMap { item -> SlackChannel? in
                guard let name = item["name"] as? String, let id = item["id"] as? String else { return nil }
                return SlackChannel(name: name, id: id)
            }
            if !items.isEmpty {
                slackChannels = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                channelsFetched = .now
            } else if slackChannels.isEmpty {
                show("Couldn't load your Slack channels")
            }
            return
        }
        guard let cardId = (event["cardId"] as? String).flatMap(UUID.init),
              let card = cards.first(where: { $0.id == cardId }) else { return }
        card.lastActive = .now
        if event["ev"] as? String != "delta" { flushDeltas() }
        switch event["ev"] as? String {
        case "init":
            card.sessionId = event["sessionId"] as? String
        case "textStart":
            if card.messages.last?.fromUser != false || !(card.messages.last?.text.isEmpty ?? true) {
                withAnimation(.smooth(duration: 0.3)) { card.messages.append(Message(fromUser: false, text: "")) }
            }
        case "delta":
            if let text = event["text"] as? String { appendDelta(text, to: card) }
        case "tool":
            let name = event["name"] as? String ?? ""
            guard !name.hasPrefix("mcp__relay__") else { break }
            card.activity = Self.pretty(name)
            // Codex's Computer Use says what each step does ("Capture current screen"): show that, not the tool's name.
            if name == "Computer Use", let step = (event["input"] as? [String: Any])?["summary"] as? String { card.activity = step }
            withAnimation(.snappy) { card.actionsToday += 1 }
            // A loaded skill (your email voice, say) gets its own line in the thread, so you can see it and turn it off.
            if name == "Skill", let skill = (event["input"] as? [String: Any])?["skill"] as? String {
                card.activity = "Using your \(skill) skill"
                withAnimation(.smooth(duration: 0.3)) { card.messages.append(Message(fromUser: false, text: "", skill: skill)) }
            }
            if name == "TodoWrite", let todos = (event["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                withAnimation(.smooth) {
                    card.todos = todos.map {
                        Todo(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending",
                             activeForm: $0["activeForm"] as? String ?? $0["content"] as? String ?? "")
                    }
                }
            }
        case "reach":
            let added = event["servers"] as? [String] ?? []
            card.reached = (card.reached + added).uniqued()
            card.activity = "Connecting " + added.map(Connector.accountName).joined(separator: ", ")
        case "block":
            if let block = Block.decode(event["block"]) {
                let message = Message(fromUser: false, text: "", block: block)
                withAnimation(.smooth(duration: 0.35)) { card.messages.append(message) }
                // A live Notion board arrives empty: Relay loads its rows itself.
                if block.type == "notion" { refreshNotion(message.id) }
            }
        case "toolDone":
            let name = event["name"] as? String ?? ""
            let input = event["input"] as? [String: Any] ?? [:]
            // An agent's email or Slack send: Relay checks the result itself instead of trusting the reply.
            if let label = Self.sendLabel(tool: name, input: input) {
                agentSendFinished(card, label: label, error: event["failed"] as? Bool == true ? event["error"] as? String ?? "unknown error" : nil)
            }
            guard event["isError"] as? Bool != true, event["failed"] as? Bool != true || Self.sendLabel(tool: name, input: input) == nil else { break }
            if card.connector.isCode, let diff = Block.diff(tool: name, input: input) {
                withAnimation(.smooth(duration: 0.35)) { card.messages.append(Message(fromUser: false, text: "", block: diff)) }
            }
            // Excalidraw's create_view draws in a host UI Relay doesn't have: render its elements as a drawing block.
            if name.lowercased().contains("excalidraw"), name.hasSuffix("__create_view"), let raw = input["elements"] as? String {
                let previous = card.messages.last { $0.block?.type == "drawing" }?.block?.elements
                if let elements = DrawingSkeleton.resolve(raw, previous: previous) {
                    withAnimation(.smooth(duration: 0.35)) {
                        card.messages.append(Message(fromUser: false, text: "", block: Block(type: "drawing", elements: elements)))
                    }
                }
            }
            crossCardNotice(from: card, tool: name, input: input)
        case "stalled":
            // The sidecar's watchdog stopped a tool call that hung; the card carries on without it.
            let tool = Self.pretty(event["name"] as? String ?? "")
            let minutes = event["minutes"] as? Int ?? 0
            withAnimation(.smooth(duration: 0.3)) {
                card.messages.append(Message(fromUser: false, text: "\(tool) hung for \(minutes) min, so Relay stopped it", note: true))
            }
            card.activity = "Carrying on without \(tool)"
            save()
        case "needsPermission":
            let input = event["input"] as? [String: Any] ?? [:]
            let detail = ["command", "file_path", "query", "q", "subject", "summary", "text"]
                .lazy.compactMap { input[$0] as? String }.first ?? ""
            let tool = event["tool"] as? String ?? ""
            let ask = PermissionAsk(
                id: event["reqId"] as? String ?? "", tool: Self.pretty(tool),
                detail: detail, canAlways: event["canAlways"] as? Bool ?? false,
                diff: Block.diff(tool: tool, input: input), rawTool: tool, sendLabel: Self.sendLabel(tool: tool, input: input))
            // Parallel calls (two WebFetches) ask at once; replacing the first would leave its call waiting forever
            // on an approval no longer on screen (the memo card on 2026-10-06), so later ones wait their turn.
            if card.ask == nil { withAnimation(.smooth(duration: 0.3)) { card.ask = ask } } else { card.queuedAsks.append(ask) }
            // A card working in the background (an @mention, the night shift) taps you on the shoulder.
            if card.id != focusedId { toast(card.connector, "\(card.connector.name) needs you", "Allow \(Self.pretty(tool))?", target: card.id) }
        case "done":
            forgetPending(agentSendsOn: card)
            card.messages.removeAll { !$0.fromUser && $0.text.isEmpty && $0.block == nil }
            if event["subtype"] as? String == "error_during_execution" {
                card.messages.append(Message(fromUser: false, text: "Stopped", note: true))
            }
            withAnimation(.smooth(duration: 0.3)) {
                card.running = false
                card.activity = nil
                card.ask = nil
                card.queuedAsks = []
            }
            if !card.connector.isMeta { requestSuggestions(for: card) }
            if card.nightShift { nightCardFinished(card) }
            if card.routedFrom != nil { routedFinished(card) }
            save()
            if ProcessInfo.processInfo.environment["RELAY_AUTOPROMPT"] != nil {
                print("CARD:", card.connector.name, "| STATUS:", card.statusText, "| REPLY:", card.messages.last?.text ?? ""); fflush(stdout)
            }
        case "suggestions":
            if let items = event["items"] as? [String], items.count == 3 {
                withAnimation(.smooth(duration: 0.3)) { card.suggestions = items }
                save()
            }
        case "error":
            forgetPending(agentSendsOn: card)
            card.messages.append(Message(fromUser: false, text: "Something went wrong: \(event["message"] as? String ?? "")"))
            card.running = false
        case "mail":
            mailFinished(card, event)
        case "substackSaved":
            substackSaved(card, event)
        case "closed":
            card.opened = false
            card.running = false
        default: break
        }
    }

    /// When a card changes something in another connector (Gmail booking a Calendar event…), tell that card.
    private func crossCardNotice(from source: Card, tool: String, input: [String: Any]) {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", parts[1] != "relay" else { return }
        let server = parts[1].lowercased()
        let action = Self.pretty(tool)
        let readVerbs = ["get", "list", "search", "read", "find", "query", "fetch", "retrieve", "check", "view", "download"]
        guard !readVerbs.contains(where: { action.lowercased().hasPrefix($0) }) else { return }
        guard let connector = Connector.all.first(where: { c in c.serverMatches.contains { server.contains($0) } }),
              connector.id != source.connector.id else { return }
        let subject = ["summary", "subject", "title", "name", "text"].lazy.compactMap { input[$0] as? String }.first
        let detail = action.prefix(1).uppercased() + action.dropFirst() + (subject.map { " · " + $0.prefix(60) } ?? "")
        let target = cards.first { $0.connector.id == connector.id }
        if let target {
            target.pendingContext.append("the \(source.connector.name) card did “\(detail)” in \(connector.name)")
            withAnimation(.smooth) {
                target.messages.append(Message(fromUser: false, text: "From \(source.connector.name): \(detail)", note: true))
            }
        }
        toast(connector, connector.name, "From \(source.connector.name) · \(detail)", target: target?.id)
        save()
    }

    /// A glass toast, top right; click it to go to `target`.
    func toast(_ connector: Connector, _ title: String, _ detail: String, target: UUID?, seconds: Double = 4.5) {
        let toast = CrossToast(connector: connector, title: title, detail: detail, target: target)
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst() }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(.smooth(duration: 0.3)) { toasts.removeAll { $0.id == toast.id } }
        }
    }

    func openToast(_ toast: CrossToast) {
        withAnimation(.smooth) { toasts.removeAll { $0.id == toast.id } }
        if let id = toast.target, let card = cards.first(where: { $0.id == id }) { open(card) }
    }

    /// The sidecar died and is restarting: sessions are gone, so cards reopen (resuming by id) on their next message.
    private func sidecarRestarted() {
        reportInterruptedSends(sidecarOnly: true)
        SubstackAccount.shared.resend()
        for card in cards {
            card.opened = false
            if card.running {
                card.messages.removeAll { !$0.fromUser && $0.text.isEmpty && $0.block == nil }
                card.messages.append(Message(fromUser: false, text: "Connection to Claude restarted — send that again", note: true))
            }
            withAnimation(.smooth) {
                card.running = false
                card.activity = nil
                card.ask = nil
                card.queuedAsks = []
            }
        }
    }

    private func requestSuggestions(for card: Card) {
        let transcript = card.messages.suffix(6).filter { $0.note != true }
            .map { ($0.fromUser ? "user: " : "assistant: ") + $0.text.prefix(400) }
            .joined(separator: "\n")
        // "Codex" alone reads as a book ("Search the codex"): say what it is.
        let connector = card.connector.isCodex ? "Codex, OpenAI's agent (code, image generation, using Mac apps)" : card.connector.name
        bridge.send(["op": "suggest", "cardId": card.id.uuidString, "connector": connector, "transcript": transcript])
    }

    /// One line of plain text from a markdown reply, for previews.
    static func plain(_ text: String) -> String {
        var out = text
        for token in ["**", "__", "`", "#"] { out = out.replacingOccurrences(of: token, with: "") }
        return out.replacingOccurrences(of: "\n- ", with: " · ").replacingOccurrences(of: "\n", with: " ")
    }

    /// For a tool that sends something (an email, a Slack post), what the undo bar says; nil for everything else.
    static func sendLabel(tool: String, input: [String: Any]) -> String? {
        let action = (tool.components(separatedBy: "__").last ?? tool).lowercased()
        guard tool.hasPrefix("mcp__"), !action.contains("draft"),
              action.contains("send_") || action.hasPrefix("send") || action.hasPrefix("reply") || action.contains("post_message") || action.contains("schedule_message")
        else { return nil }
        let to = (input["to"] as? [String])?.joined(separator: ", ") ?? input["to"] as? String
        if let to, !to.isEmpty { return "Sending to " + to }
        if let channel = input["channel_id"] as? String ?? input["channel"] as? String { return "Posting in " + channel }
        return "Sending"
    }

    /// `mcp__gmail-mcp__search_emails` → "search emails".
    static func pretty(_ tool: String) -> String {
        let last = tool.components(separatedBy: "__").last ?? tool
        return last.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// Turn a skill off (or back on) for every card. Idle cards restart now so it takes effect on their next message;
    /// a card that's working keeps its session until it finishes and goes idle.
    func setSkill(_ name: String, on: Bool) {
        skillsOff = on ? skillsOff.filter { $0 != name } : (skillsOff + [name]).uniqued()
        for card in cards where card.opened && !card.running && card.ask == nil {
            bridge.send(["op": "close", "cardId": card.id.uuidString])
            card.opened = false
        }
    }

    func save() { Store.save(cards, focusedId: focusedId) }
    func shutdown() { dictation.stop(); save(); bridge.stop() }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// A Slack channel you're in: its name without "#", and Slack's id for it.
struct SlackChannel: Codable, Hashable {
    var name: String
    var id: String

    static var cached: [SlackChannel] {
        (UserDefaults.standard.data(forKey: "relay.slackChannels")).flatMap { try? JSONDecoder().decode([SlackChannel].self, from: $0) } ?? []
    }
    static func cache(_ channels: [SlackChannel]) {
        if let data = try? JSONEncoder().encode(channels) { UserDefaults.standard.set(data, forKey: "relay.slackChannels") }
    }
}
