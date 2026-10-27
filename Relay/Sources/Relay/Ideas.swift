import AppKit
import SwiftUI

/// A night-shift idea queued to start at the night-shift hour.
struct NightTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var idea: Block.Idea
}

/// What the Ideas and Discover cards know about you: connectors, open cards, recent folders and recent prompts.
/// Sent ahead of each message to those cards (not shown in the thread).
@MainActor
enum Briefing {
    static func summary(_ model: RelayModel, night: Bool) -> String {
        var lines = ["Today is \(Date.now.formatted(date: .complete, time: .shortened))."]
        lines.append("Connected MCP servers: " + (model.servers.isEmpty ? "(still loading)" : model.servers.joined(separator: ", ")) + ".")
        let other = model.serverStatus.filter { $0.value != "connected" }.map { "\($0.key) (\($0.value))" }.sorted()
        if !other.isEmpty { lines.append("Installed but not connected: " + other.joined(separator: ", ") + ".") }
        lines.append("My Relay cards: " + model.cards.map { "\($0.connector.name) (\($0.subtitle))" }.joined(separator: ", ") + ".")
        if !model.recentFolders.isEmpty {
            lines.append("Recent Claude Code folders: " + model.recentFolders.prefix(8).joined(separator: ", ") + ".")
        }
        let asked = model.cards.flatMap { card in
            card.messages.filter { $0.fromUser }.suffix(3).map { "[\(card.connector.name)] \($0.text.prefix(140))" }
        }
        if !asked.isEmpty { lines.append("Recently asked in Relay:\n" + asked.suffix(15).map { "- " + $0 }.joined(separator: "\n")) }
        let history = recentPrompts()
        if !history.isEmpty { lines.append("Recently asked Claude Code (newest first):\n" + history.map { "- " + $0 }.joined(separator: "\n")) }
        if !model.nightQueue.isEmpty {
            lines.append("Already queued for tonight: " + model.nightQueue.map(\.idea.title).joined(separator: "; ") + ".")
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now)!.formatted(.iso8601.year().month().day())
        let done = model.ideaLog.filter { String($0.prefix(10)) >= cutoff }.map { String($0.dropFirst(11)) }
        if !done.isEmpty {
            lines.append("Ideas I already started from Relay, done or in progress; don't suggest these again or reworded: " + done.suffix(30).joined(separator: "; ") + ".")
        }
        if !model.dismissedIdeas.isEmpty {
            lines.append("Ideas I dismissed, don't suggest these or close variants: " + model.dismissedIdeas.suffix(30).joined(separator: "; ") + ".")
        }
        lines.append(night ? nightMode : nowMode)
        return "(Context from Relay, not from me:\n" + lines.joined(separator: "\n") + ")"
    }

    static let nowMode = """
    Mode: now. Ideas are things I could get done in the next few hours, each runnable right away by one card, \
    2 to 60 minutes each. Prefer things with a deadline or someone waiting on me. Set night to false. \
    Mark priority high only for the one or two that matter most today.
    """

    static let nightMode = """
    Mode: night shift. First work out what matters most to me this week: deadlines and commitments in my calendar \
    and email, the projects my recent Claude Code prompts and repos keep coming back to, and what people are waiting \
    on me for. Then suggest only the big pieces of that work an agent can move forward on its own over 1 to 5 hours \
    while I sleep: building or fixing a feature in one of those repos (it runs on its own git worktree branch), a \
    test suite or bug hunt for code I'm actively changing, deep research with many sources written up as a Notion \
    page or Google Doc, or a full pass through a backlog that ends in drafts shown in Relay (never saved to Gmail or Slack). \
    Not night-shift work: a single email reply, a short draft, a reminder, a summary of one thread, or anything I \
    could do in under 30 minutes. Leave those for Now mode even if they're urgent; don't stretch them to look long. \
    Two or three strong tasks beat five padded ones. In `why`, say why it matters now and why it takes hours. \
    Mark priority high for the task tied to my nearest deadline or most active project. \
    Nothing may send, post, delete, accept or decline; that waits for me in the morning. Set minutes between 60 and \
    300 as an honest estimate, set night to true, give code ideas an absolute folder from my recent folders, and make \
    each prompt a full brief: the goal, where to look, the steps, and what done looks like.
    """

    /// What a night-shift card is told before its task.
    static func nightPreamble(_ idea: Block.Idea, worktree: Bool) -> String {
        var text = """
        Night shift: you're running unattended while I sleep. Work on this for up to about \
        \(max(1, Int((idea.minutes / 60).rounded()))) hour(s) until it's done. Don't stop to ask me questions; make \
        reasonable calls and note them. Never send, post, delete, accept or decline anything. Show any drafts in this \
        thread with show_email or show_slack_message and don't save them to Gmail or Slack; I'll save or send them myself.
        """
        if worktree { text += " You're on your own git worktree branch: commit your work there with clear messages, and don't push." }
        text += " When you finish, reply with a short morning summary: what you did, where it is, and what needs me.\n\nTask: " + idea.prompt
        return text
    }

    /// The last prompts from ~/.claude/history.jsonl, newest first: what you've been asking Claude Code lately.
    static func recentPrompts(limit: Int = 25) -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/history.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var seen = Set<String>()
        var out: [String] = []
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = (obj["display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count > 12, !text.hasPrefix("/") else { continue }
            let project = (obj["project"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            let entry = "[\(project)] " + text.replacingOccurrences(of: "\n", with: " ").prefix(160)
            if seen.insert(entry).inserted { out.append(entry) }
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - Discover

struct ConnectorPicksBlock: View {
    let block: Block
    let model: RelayModel
    let card: Card?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(block.title ?? "Connectors to try").font(.system(size: 13.5, weight: .semibold))
            ForEach(Array((block.picks ?? []).enumerated()), id: \.offset) { index, pick in
                if index > 0 { Divider().opacity(0.4) }
                HStack(alignment: .top, spacing: 12) {
                    Monogram(name: pick.name, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(pick.name).font(.system(size: 14, weight: .semibold))
                            Text(pick.category).font(.rounded(11, .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.fill.tertiary, in: .capsule)
                        }
                        Text(pick.why).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let setup = pick.setup {
                            Text(setup).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Set up") {
                            if let card { model.send("Help me set up \(pick.name)", to: card) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(card?.running ?? true)
                        if let url = pick.url, URL(string: url) != nil {
                            Button("Learn more") { model.openBlock(Block(type: "link", title: pick.name, url: url)) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .font(.rounded(12, .medium))
                }
            }
        }
        .padding(14)
    }
}

/// A letter tile for products without a logo: the same gradient every time for the same name.
struct Monogram: View {
    let name: String
    var size: CGFloat = 36

    private var colors: [Color] {
        let palettes: [[Color]] = [[.blue, .indigo], [.purple, .pink], [.orange, .red], [.teal, .blue], [.green, .teal], [.pink, .orange], [.indigo, .purple]]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palettes[hash % palettes.count]
    }

    var body: some View {
        if let known = Connector.all.first(where: { !$0.isMeta && name.localizedCaseInsensitiveContains($0.name) }) {
            ConnectorIcon(connector: known, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Text(name.prefix(1).uppercased()).font(.rounded(size * 0.46, .bold)).foregroundStyle(.white))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.12), radius: size * 0.06, y: size * 0.03)
        }
    }
}

// MARK: - Ideas

struct IdeasBlock: View {
    let block: Block
    let model: RelayModel

    private var night: Bool { block.night ?? false }
    private var ideas: [Block.Idea] {
        let open = (block.ideas ?? []).filter { !model.dismissedIdeas.contains($0.title) }
        return open.filter { $0.priority == "high" } + open.filter { $0.priority != "high" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if night { Image(systemName: "moon.stars.fill").foregroundStyle(.indigo) }
                Text(block.title ?? "Ideas").font(.system(size: 13.5, weight: .semibold))
            }
            ForEach(Array(ideas.enumerated()), id: \.element.title) { index, idea in
                VStack(alignment: .leading, spacing: 12) {
                    if index > 0 { Divider().opacity(0.4) }
                    IdeaRow(idea: idea, night: night, model: model)
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .move(edge: .leading))))
            }
            if ideas.isEmpty {
                Text("All dismissed. Refresh for more.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct IdeaRow: View {
    let idea: Block.Idea
    let night: Bool
    let model: RelayModel

    private var connector: Connector { Connector.route(idea.connector) }
    private var queued: Bool { model.nightQueue.contains { $0.idea == idea } }
    private var started: Bool { model.startedIdeas.contains(idea) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ConnectorIcon(connector: connector, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(idea.title).font(.system(size: 14, weight: .semibold))
                    Text(Self.duration(idea.minutes)).font(.rounded(11, .semibold).monospacedDigit())
                        .foregroundStyle(night ? AnyShapeStyle(.indigo) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(night ? AnyShapeStyle(Color.indigo.opacity(0.14)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                    if idea.priority == "high" {
                        Text("Priority").font(.rounded(11, .semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: .capsule)
                    }
                }
                Text(idea.why).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if connector.isCode, let folder = idea.folder {
                    Text(Connector.shortPath(folder)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if night {
                    Button { model.toggleQueued(idea) } label: {
                        Label(queued ? "Queued" : "Tonight", systemImage: queued ? "checkmark" : "moon.zzz")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.bordered).tint(queued ? .indigo : nil)
                    Button("Start now") { model.runIdea(idea, night: true) }
                        .buttonStyle(.bordered).disabled(started)
                } else {
                    Button(started ? "Started" : "Do it") { model.runIdea(idea, night: false) }
                        .buttonStyle(.borderedProminent).disabled(started)
                }
            }
            .controlSize(.small)
            .font(.rounded(12, .medium))
        }
        .contentShape(.rect)
        .contextMenu {
            if night {
                Button(queued ? "Remove from Tonight" : "Queue for Tonight") { model.toggleQueued(idea) }
            } else {
                Button("Do It") { model.runIdea(idea, night: false) }.disabled(started)
            }
            Divider()
            Button("Dismiss", systemImage: "xmark") { model.dismissIdea(idea) }
        }
    }

    static func duration(_ minutes: Double) -> String {
        minutes >= 60 ? "\((minutes / 60).formatted(.number.precision(.fractionLength(0...1)))) hr" : "\(Int(minutes)) min"
    }
}

/// Under the Ideas card header: Now / Night shift, and tonight's queue.
struct IdeasStrip: View {
    let card: Card
    @Bindable var model: RelayModel

    /// This card's mode; picking one also becomes the default for the next Ideas card.
    private var mode: Binding<Bool> {
        Binding(get: { card.nightMode }, set: { card.nightMode = $0; model.nightMode = $0; model.save() })
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: mode.animation(.smooth)) {
                Label("Now", systemImage: "sun.max").tag(false)
                Label("Night shift", systemImage: "moon.stars").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if !model.nightQueue.isEmpty { queueMenu }
            else if card.nightMode {
                Text("Queue ideas to start at \(model.nightStartLabel)").font(.rounded(12)).foregroundStyle(.secondary)
            }
            Button { model.send(card.nightMode ? "Night shift ideas" : "Ideas for right now", to: card) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26).background(.fill.tertiary, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(card.running)
            .help(card.nightMode ? "Suggest night-shift tasks" : "Suggest things to do now")
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }

    private var queueMenu: some View {
        Menu {
            Section("Starts at") {
                ForEach([21, 22, 23, 0, 1, 2], id: \.self) { hour in
                    Toggle(RelayModel.hourLabel(hour), isOn: Binding(get: { model.nightHour == hour }, set: { _ in model.nightHour = hour }))
                }
            }
            Button("Start now") { model.startNightShift() }
            Section("Queued") {
                ForEach(model.nightQueue) { task in
                    Button("Remove “\(task.idea.title)”") { model.toggleQueued(task.idea) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                Text("\(model.nightQueue.count)").contentTransition(.numericText(value: Double(model.nightQueue.count)))
                Text("queued · \(model.nightStartLabel)")
            }
            .font(.rounded(12, .medium).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.indigo.opacity(0.14), in: .capsule)
            .animation(.snappy, value: model.nightQueue.count)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// First look at a Discover or Ideas card: what it does, and one button to start.
struct MetaEmptyCard: View {
    let card: Card
    let model: RelayModel

    private var night: Bool { card.connector.isIdeas && card.nightMode }

    var body: some View {
        VStack(spacing: 12) {
            ConnectorIcon(connector: card.connector, size: 56, symbol: night ? "moon.stars.fill" : nil)
            Text(card.connector.isDiscover ? "Discover new connectors" : (night ? "What could run tonight?" : "What could you get done?"))
                .font(.system(size: 17, weight: .semibold))
            Text(card.connector.isDiscover
                 ? "Looks at your inbox, calendar and repos, then finds three connectors worth adding, and why."
                 : (night ? "Long tasks that run while you sleep, each on its own branch or as drafts. Nothing gets sent."
                          : "Three to five things to do now, from your calendar, inbox, Slack and recent work."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .contentTransition(.opacity)
            Button {
                model.send(card.connector.isDiscover ? "Find 3 connectors for me" : (night ? "Night shift ideas" : "Ideas for right now"), to: card)
            } label: {
                Text(card.connector.isDiscover ? "Find connectors" : (night ? "Suggest night-shift tasks" : "Suggest ideas"))
                    .font(.rounded(13.5, .semibold)).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(night ? .indigo : nil)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
        .animation(.smooth, value: night)
    }
}

// MARK: - Running ideas and the night shift

extension RelayModel {
    /// "Do it" / "Start now": a fresh card for the idea's connector, running the idea's prompt.
    func runIdea(_ idea: Block.Idea, night: Bool) {
        startedIdeas.insert(idea)
        ideaLog.append(Card.today + " " + idea.title)
        let connector = Connector.route(idea.connector)
        let folder = connector.isCode ? (idea.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? Connector.defaultFolder) : nil
        let asked = handoffContext(for: idea)
        guard night else {
            startIdea(idea, on: newCard(connector, folder: folder), prompt: asked + idea.prompt)
            return
        }
        // Night-shift code runs on its own worktree branch, so it can edit freely without touching your checkout.
        guard connector.isCode, let folder else {
            startIdea(idea, on: newCard(connector, nightShift: true), prompt: asked + Briefing.nightPreamble(idea, worktree: false))
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = Worktree.create(from: folder)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let path = (try? result.get()) ?? folder
                let card = newCard(connector, folder: path, nightShift: true)
                startIdea(idea, on: card, prompt: asked + Briefing.nightPreamble(idea, worktree: path != folder))
            }
        }
    }

    /// The bubble shows the idea's title; the full brief it was started with sits behind it, one click away.
    private func startIdea(_ idea: Block.Idea, on card: Card, prompt: String) {
        send(idea.title, to: card, prompt: prompt)
        if let last = card.messages.indices.last, card.messages[last].fromUser { card.messages[last].brief = idea.prompt }
    }

    /// When you asked for this hand-off in a conversation ("kick off a Claude Code card for…"), the new card hears
    /// that conversation in your words too, not only the Ideas card's summary of it.
    private func handoffContext(for idea: Block.Idea) -> String {
        guard let source = cards.first(where: { $0.messages.contains { $0.block?.ideas?.contains(idea) == true } }),
              let at = source.messages.firstIndex(where: { $0.block?.ideas?.contains(idea) == true }) else { return "" }
        let before = source.messages[..<at].filter { $0.note != true }.suffix(6)
        let starters = Set(source.connector.starters + ["Ideas for right now", "Night shift ideas"])
        guard before.contains(where: { $0.fromUser && !starters.contains($0.text) }) else { return "" }
        let lines = before.compactMap { message -> String? in
            let said = message.block?.plainText ?? message.text
            guard !said.isEmpty else { return nil }
            return (message.fromUser ? "me: " : "\(source.connector.name): ") + String(said.prefix(message.fromUser ? 2000 : 700))
        }
        return "(I asked for this in my \(source.connector.name) card in Relay. Our conversation there, in my words:\n"
            + lines.joined(separator: "\n") + ")\n\n"
    }

    /// Right-click → Dismiss: the idea leaves every Ideas card (and tonight's queue) and isn't suggested again.
    func dismissIdea(_ idea: Block.Idea) {
        withAnimation(.snappy) {
            dismissedIdeas.removeAll { $0 == idea.title }
            dismissedIdeas.append(idea.title)
            nightQueue.removeAll { $0.idea == idea }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func toggleQueued(_ idea: Block.Idea) {
        withAnimation(.snappy) {
            if let index = nightQueue.firstIndex(where: { $0.idea == idea }) { nightQueue.remove(at: index) }
            else { nightQueue.append(NightTask(idea: idea)) }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// Start everything queued for tonight, one card each.
    func startNightShift() {
        let tasks = nightQueue
        guard !tasks.isEmpty else { return }
        nightQueue = []
        for task in tasks { runIdea(task.idea, night: true) }
        updateNightActivity()
    }

    /// Checks every 30 seconds whether it's the night-shift hour (within six hours of it, in case the Mac was asleep).
    func startNightClock() {
        updateNightActivity()
        Task { [weak self] in
            while let self {
                let hour = Calendar.current.component(.hour, from: .now)
                if !nightQueue.isEmpty, (hour - nightHour + 24) % 24 < 6 { startNightShift() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// No idle sleep while there is night work queued or running (the lid closed on battery still sleeps).
    func updateNightActivity() {
        let busy = !nightQueue.isEmpty || cards.contains { $0.nightShift && $0.running }
        if busy, nightActivity == nil {
            nightActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Relay night shift")
        } else if !busy, let activity = nightActivity {
            ProcessInfo.processInfo.endActivity(activity)
            nightActivity = nil
        }
    }

    func nightCardFinished(_ card: Card) {
        updateNightActivity()
        let title = card.messages.last { $0.fromUser }?.text ?? card.connector.name
        toast(card.connector, "Night shift · \(card.connector.name)", "Finished: \(title)", target: card.id, seconds: 8)
    }

    var nightStartLabel: String { Self.hourLabel(nightHour) }

    static func hourLabel(_ hour: Int) -> String {
        var parts = DateComponents()
        parts.hour = hour
        return Calendar.current.date(from: parts)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}
