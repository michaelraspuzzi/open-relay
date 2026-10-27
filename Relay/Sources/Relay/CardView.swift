import SwiftUI

/// The platform's real logo on a small white tile, like an app icon.
/// Relay's own cards (Ideas, Discover) get an SF Symbol on a gradient tile instead.
struct ConnectorIcon: View {
    let connector: Connector
    var size: CGFloat = 30
    /// Overrides the connector's symbol (the Ideas card turns to a moon in night-shift mode).
    var symbol: String? = nil

    private var gradient: [Color] {
        if symbol?.hasPrefix("moon") == true { return [.indigo, Color(red: 0.12, green: 0.1, blue: 0.35)] }
        if connector.isPrep { return [.mint, .teal, .blue] }
        if connector.id == "crm" { return [.pink, .purple] }
        if connector.id == "memo" { return [Color(white: 0.45), .black] }
        if connector.isFollowups { return [.orange, .pink] }
        if connector.isLinkedIn { return [Color(red: 0.2, green: 0.55, blue: 0.95), .linkedIn] }
        return connector.isDiscover ? [.cyan, .blue, .purple] : [.yellow, .orange]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(connector.symbol == nil ? AnyShapeStyle(.white)
                      : AnyShapeStyle(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: .black.opacity(0.12), radius: size * 0.06, y: size * 0.03)
            if let name = symbol ?? connector.symbol {
                Image(systemName: name).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            } else if let logo = Assets.logo(connector.logo) {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                    .padding(size * (connector.logo == "claude" ? 0.08 : 0.17))
            }
        }
        .frame(width: size, height: size)
    }
}

struct CardView: View {
    let card: Card
    let isFocused: Bool
    let model: RelayModel

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 8)
            CardHeader(card: card, model: model)
            if card.connector.isIdeas { IdeasStrip(card: card, model: model) }
            if !card.todos.isEmpty { TodoStrip(todos: card.todos) }
            if card.connector.isLinkedIn { LinkedInStrip() }
            if card.connector.isSubstack { SubstackStrip(model: model) }
            Divider().opacity(0.4)
            ThreadView(card: card, isFocused: isFocused, model: model)
            Divider().opacity(0.4)
            CardFooter(card: card, model: model)
        }
        .glassCard(cornerRadius: 28)
        // Night shift: the Ideas card (and cards the night shift started) take on a deep indigo cast.
        .overlay {
            if (card.connector.isIdeas && card.nightMode) || card.nightShift {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [.indigo.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.5), value: card.nightMode)
    }
}

struct CardHeader: View {
    let card: Card
    let model: RelayModel

    var body: some View {
        HStack(spacing: 11) {
            ConnectorIcon(connector: card.connector, symbol: card.connector.isIdeas && card.nightMode ? "moon.stars.fill" : nil)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(card.connector.name).font(.system(size: 14, weight: .semibold))
                    if card.nightShift {
                        Image(systemName: "moon.stars.fill").font(.system(size: 11)).foregroundStyle(.indigo).help("Started by the night shift")
                    }
                }
                SourceMenu(card: card, model: model)
            }
            Spacer()
            StatusPill(card: card)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
    }
}

/// The subtitle under the card name: which workspace (Notion, Slack…) or folder (Claude Code) this card uses.
struct SourceMenu: View {
    let card: Card
    let model: RelayModel

    var body: some View {
        Menu {
            if card.connector.usesFolder { folderItems } else { accountItems }
        } label: {
            HStack(spacing: 3) {
                Text(card.subtitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var accountItems: some View {
        let accounts = model.accounts(for: card)
        Section("\(card.connector.name) accounts") {
            Toggle("All accounts", isOn: Binding(get: { card.account == nil }, set: { _ in model.switchAccount(card, to: nil) }))
            ForEach(accounts, id: \.self) { account in
                Toggle(Connector.accountName(account),
                       isOn: Binding(get: { card.account == account }, set: { _ in model.switchAccount(card, to: account) }))
            }
        }
        if accounts.count < 2 {
            Section {
                Text("Add another \(card.connector.name) workspace as a connector in claude.ai or Claude Code, and it shows up here.")
            }
        }
        Divider()
        Button("New \(card.connector.name) card") { model.newCard(like: card) }
    }

    @ViewBuilder private var folderItems: some View {
        // Codex starts in Relay's workspace; Claude Code in the default repo.
        let first = card.connector.isCodex ? Connector.workspace : Connector.defaultFolder
        Section("Recent folders") {
            ForEach(([first] + model.recentFolders).uniqued(), id: \.self) { folder in
                Toggle(folder == Connector.workspace ? "Relay workspace" : Connector.shortPath(folder),
                       isOn: Binding(get: { card.cwd == folder }, set: { _ in model.switchFolder(card, to: folder) }))
            }
        }
        Divider()
        Button("Choose Folder…") { model.chooseFolder(for: card) }
        Button("New \(card.connector.name) card here") { model.newCard(like: card) }
        if card.connector.isCode { Button("New card in a git worktree") { model.newWorktreeCard(from: card) } }
    }
}

/// A Claude Code card's live task list (its TodoWrite plan): one line, click to expand.
struct TodoStrip: View {
    let todos: [Todo]
    @State private var expanded = false

    private var done: Int { todos.filter { $0.status == "completed" }.count }
    private var current: Todo? { todos.first { $0.status == "in_progress" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(max(todos.count, 1)))
                        .progressViewStyle(.circular).controlSize(.mini)
                    Text("\(done) of \(todos.count)").font(.rounded(12, .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(done)))
                        .animation(.snappy, value: done)
                    Text(current?.activeForm ?? (done == todos.count ? "All done" : "Up next: \(todos.first { $0.status == "pending" }?.content ?? "")"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                    HStack(spacing: 8) {
                        Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : (todo.status == "in_progress" ? "circle.dotted" : "circle"))
                            .foregroundStyle(todo.status == "completed" ? AnyShapeStyle(.green) : AnyShapeStyle(todo.status == "in_progress" ? .blue : .secondary))
                            .font(.system(size: 12))
                        Text(todo.content).font(.system(size: 12.5)).foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }
}

struct CardFooter: View {
    let card: Card
    let model: RelayModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.newCard(like: card) } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .circle)
            }
            .buttonStyle(.plain)
            .help("New \(card.connector.name) card")
            Spacer()
            ForEach(chips, id: \.self) { suggestion in
                Button { model.send(suggestion, to: card) } label: {
                    Text(suggestion).font(.rounded(12.5, .medium)).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.fill.tertiary, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(card.running)
                .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .animation(.smooth, value: chips)
    }

    /// The Ideas card's chips follow its Now / Night shift mode.
    private var chips: [String] {
        guard card.connector.isIdeas, card.nightMode else { return card.suggestions }
        return ["Night shift ideas", "Night work for my repos", "A research report by morning"]
    }
}

/// "Working", "Needs you", or "12 actions today", where the number rolls as it changes.
struct StatusPill: View {
    let card: Card

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(card.statusColor).frame(width: 6, height: 6)
            if card.ask == nil, !card.running, card.actionsToday > 0 {
                HStack(spacing: 3) {
                    Text("\(card.actionsToday)").contentTransition(.numericText(value: Double(card.actionsToday)))
                    Text(card.actionsToday == 1 ? "action today" : "actions today")
                }
            } else {
                Text(card.statusText).contentTransition(.interpolate)
            }
        }
        .font(.rounded(12, .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.fill.tertiary, in: .capsule)
        .animation(.snappy, value: card.statusText)
    }
}
