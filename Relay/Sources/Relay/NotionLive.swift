import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A Notion database shown live in a card: Relay loads its rows straight from Notion (the agent only says which one),
// shows them as a board grouped by a status or select property, or as a table, and writes your changes back:
// drag a card to another column, or tick a checkbox. Edits show at once and roll back if Notion says no.

extension UTType {
    /// A row dragged between board columns (inside Relay only).
    static let notionRow = UTType(exportedAs: "org.openrelay.relay.notion-row")
}

extension RelayModel {
    /// The Notion server a board talks through: the one the agent used, else the card's account, else the first
    /// Notion server with the API-* tools (claude.ai's Notion connector doesn't have them).
    private func notionPrefix(_ block: Block, in card: Card) -> String? {
        if let prefix = block.toolPrefix, prefix.hasPrefix("mcp__") { return prefix.hasSuffix("__") ? prefix : prefix + "__" }
        let accounts = Connector.find("notion").accounts(in: servers)
        let server = card.account ?? accounts.first { !$0.hasPrefix("claude.ai") } ?? accounts.first
        return server.map(Connector.toolPrefix)
    }

    /// Load (or reload) a board's rows from Notion.
    func refreshNotion(_ id: UUID) {
        guard notionWork[id] == nil, let (card, index) = locate(id), let block = card.messages[index].block,
              let source = block.dataSourceId, let prefix = notionPrefix(block, in: card) else { return }
        withAnimation(.smooth(duration: 0.2)) { notionWork[id] = "sync" }
        bridge.send(["op": "notion", "action": "query", "reqId": "q " + id.uuidString, "prefix": prefix, "dataSourceId": source])
    }

    /// Move a row to another column: sets the board's status or select property on that page.
    func moveNotionRow(_ id: UUID, row rowId: String, to value: String) {
        guard let block = draft(id), let group = block.groupBy,
              let prop = block.props?.first(where: { $0.name == group }), block.rows?.first(where: { $0.id == rowId })?.values[group] != value
        else { return }
        let payload: Any = value.isEmpty ? NSNull() : ["name": value]
        let title = block.rows?.first { $0.id == rowId }?.title ?? "a page"
        updateNotion(id, row: rowId, property: group, value: value, json: [group: [prop.type: payload]],
                     change: value.isEmpty ? "cleared \(group) on “\(title)”" : "moved “\(title)” to \(value)")
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Tick or untick a checkbox property.
    func toggleNotion(_ id: UUID, row rowId: String, property: String) {
        guard let block = draft(id), let row = block.rows?.first(where: { $0.id == rowId }) else { return }
        let on = row.values[property] != "true"
        updateNotion(id, row: rowId, property: property, value: on ? "true" : "false", json: [property: ["checkbox": on]],
                     change: "\(on ? "ticked" : "unticked") \(property) on “\(row.title)”")
    }

    private func updateNotion(_ id: UUID, row rowId: String, property: String, value: String, json: [String: Any], change: String) {
        guard let (card, index) = locate(id), let before = card.messages[index].block, let prefix = notionPrefix(before, in: card) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            editDraft(id) { block in
                guard let at = block.rows?.firstIndex(where: { $0.id == rowId }) else { return }
                block.rows?[at].values[property] = value
            }
        }
        let reqId = "u " + UUID().uuidString
        notionEdits[reqId] = (id, before, change)
        bridge.send(["op": "notion", "action": "update", "reqId": reqId, "prefix": prefix, "pageId": rowId, "properties": json])
    }

    func notionFinished(_ event: [String: Any]) {
        guard let reqId = event["reqId"] as? String else { return }
        let ok = event["ok"] as? Bool == true
        if event["action"] as? String == "update" {
            guard let edit = notionEdits.removeValue(forKey: reqId) else { return }
            if ok {
                locate(edit.message)?.0.pendingContext.append("I \(edit.change) on the live Notion board in Relay")
            } else {
                withAnimation(.snappy) { if let (card, index) = locate(edit.message) { card.messages[index].block = edit.before } }
                show("Notion didn't take that change — \((event["error"] as? String ?? "unknown error").prefix(120))")
            }
            return
        }
        guard let id = UUID(uuidString: String(reqId.dropFirst(2))) else { return }
        withAnimation(.smooth(duration: 0.2)) { notionWork[id] = nil }
        guard ok else {
            show("Couldn't load the Notion database — \((event["error"] as? String ?? "unknown error").prefix(120))")
            return
        }
        let props = (event["props"] as? [[String: Any]] ?? []).compactMap { item -> Block.NotionProp? in
            guard let name = item["name"] as? String, let type = item["type"] as? String else { return nil }
            return Block.NotionProp(name: name, type: type, options: item["options"] as? [String])
        }
        let rows = (event["rows"] as? [[String: Any]] ?? []).compactMap { item -> Block.NotionRow? in
            guard let id = item["id"] as? String else { return nil }
            return Block.NotionRow(id: id, url: item["url"] as? String, title: item["title"] as? String ?? "Untitled",
                                   values: item["values"] as? [String: String] ?? [:])
        }
        withAnimation(.smooth(duration: 0.3)) {
            editDraft(id) { block in
                block.props = props
                block.rows = rows
                block.synced = Date.now.formatted(.iso8601)
                // No usable group: a table. A group the agent named that isn't a status/select: the first one that is.
                if !props.contains(where: { $0.name == block.groupBy && NotionBoard.groupTypes.contains($0.type) }) {
                    block.groupBy = props.first { $0.type == "status" }?.name ?? (block.groupBy == nil ? nil : props.first { $0.type == "select" }?.name)
                }
            }
        }
    }
}

/// The board or table, inline in the card or full size (expanded).
struct NotionBoard: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    static let groupTypes: Set<String> = ["status", "select"]

    private var block: Block { model.draft(id) ?? Block(type: "notion") }
    private var props: [Block.NotionProp] { block.props ?? [] }
    private var rows: [Block.NotionRow] { block.rows ?? [] }
    private var group: Block.NotionProp? { props.first { $0.name == block.groupBy && Self.groupTypes.contains($0.type) } }
    private var showsBoard: Bool { group != nil && (block.view ?? "board") == "board" }
    private var syncing: Bool { model.notionWork[id] != nil }

    /// Properties worth a glance on each row: the agent's pick, else dates, people and selects.
    private var shown: [Block.NotionProp] {
        let picked = (block.columns ?? []).compactMap { name in props.first { $0.name == name } }
        let fallback = props.filter { ["date", "people", "select", "multi_select", "checkbox", "number"].contains($0.type) }
        return Array((picked.isEmpty ? fallback : picked).filter { $0.name != block.groupBy && $0.type != "title" }.prefix(expanded ? 5 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded { ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) } } else { content }
        }
        .padding(expanded ? 0 : 14)
        .task(id: id) {
            // Stale after five minutes: reload when the board comes back into view.
            let synced = block.synced.flatMap { try? Date($0, strategy: .iso8601) }
            if block.rows != nil, synced.map({ $0.timeIntervalSinceNow < -300 }) ?? true { model.refreshNotion(id) }
        }
    }

    @ViewBuilder private var content: some View {
            if block.rows == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading from Notion…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if rows.isEmpty {
                Text("Nothing in this database yet").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if showsBoard, let group {
                board(group)
            } else {
                table
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ConnectorIcon(connector: Connector.find("notion"), size: expanded ? 26 : 22)
            Text(block.title ?? "Notion").font(.system(size: expanded ? 16 : 13.5, weight: .semibold)).lineLimit(1)
            LiveBadge(syncing: syncing, synced: block.synced)
            Spacer(minLength: 6)
            if group != nil {
                Picker("", selection: Binding(get: { showsBoard ? "board" : "table" },
                                              set: { view in model.editDraft(id) { $0.view = view } })) {
                    Image(systemName: "rectangle.split.3x1").tag("board").help("Board")
                    Image(systemName: "tablecells").tag("table").help("Table")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            Button { model.refreshNotion(id) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(syncing).help("Reload from Notion")
            if let url = block.url.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in Notion")
            }
            if !expanded {
                Button { model.openBlock(block, messageId: id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open full size")
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Board

    private func columns(_ group: Block.NotionProp) -> [String] {
        var names = group.options ?? []
        for row in rows { if let value = row.values[group.name], !names.contains(value) { names.append(value) } }
        if rows.contains(where: { ($0.values[group.name] ?? "").isEmpty }) { names.insert("", at: 0) }
        return names
    }

    @ViewBuilder private func board(_ group: Block.NotionProp) -> some View {
        let all = columns(group)
        // Inline there's no sideways scrolling (that swipes cards), so show the busiest four columns.
        let visible = expanded ? all : Array(all.filter { name in rows.contains { ($0.values[group.name] ?? "") == name } }.prefix(4))
        let lanes = HStack(alignment: .top, spacing: 10) {
            ForEach(visible, id: \.self) { name in
                BoardColumn(name: name, rows: rows.filter { ($0.values[group.name] ?? "") == name }, columns: all, shown: shown,
                            limit: expanded ? .max : 4, width: expanded ? 250 : nil, id: id, model: model)
            }
        }
        if expanded {
            ScrollView(.horizontal) { lanes.padding(.bottom, 8) }
        } else {
            lanes
            if all.count > visible.count {
                Button("\(all.count - visible.count) more column\(all.count - visible.count == 1 ? "" : "s")") { model.openBlock(block, messageId: id) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Table

    private var table: some View {
        let limit = expanded ? rows.count : 8
        let columns = (group.map { [$0] } ?? []) + shown
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.name) { Text($0.name).frame(width: expanded ? 150 : 96, alignment: .leading) }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ForEach(rows.prefix(limit)) { row in
                HStack(spacing: 10) {
                    Text(row.title).font(.system(size: expanded ? 13.5 : 12.5, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { open(row) }
                    ForEach(columns, id: \.name) { prop in
                        cell(row, prop).frame(width: expanded ? 150 : 96, alignment: .leading)
                    }
                }
                .padding(.vertical, expanded ? 7 : 5)
                Divider().opacity(0.3)
            }
            if rows.count > limit {
                Button("+\(rows.count - limit) more") { model.openBlock(block, messageId: id) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func cell(_ row: Block.NotionRow, _ prop: Block.NotionProp) -> some View {
        let value = row.values[prop.name] ?? ""
        if prop.type == "checkbox" {
            Button { model.toggleNotion(id, row: row.id, property: prop.name) } label: {
                Image(systemName: value == "true" ? "checkmark.square.fill" : "square")
                    .foregroundStyle(value == "true" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
        } else if Self.groupTypes.contains(prop.type), prop.name == block.groupBy {
            Menu {
                ForEach(columns(prop), id: \.self) { option in
                    Button(option.isEmpty ? "No \(prop.name)" : option) { model.moveNotionRow(id, row: row.id, to: option) }
                }
            } label: { StatusTag(name: value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        } else {
            Text(NotionBoard.display(value, type: prop.type)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func open(_ row: Block.NotionRow) {
        if let url = row.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    /// Dates without the time noise, checkboxes as ticks.
    static func display(_ value: String, type: String) -> String {
        if type == "checkbox" { return value == "true" ? "✓" : "" }
        if type == "date" || type.hasSuffix("_time"), let date = try? Date(String(value.prefix(25)), strategy: .iso8601) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        if type == "date", value.count >= 10, let date = try? Date(String(value.prefix(10)) + "T12:00:00Z", strategy: .iso8601) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return value
    }
}

/// "Live" with a green dot (synced in the last few minutes), or a spinner while syncing.
private struct LiveBadge: View {
    let syncing: Bool
    let synced: String?

    var body: some View {
        HStack(spacing: 4) {
            if syncing {
                ProgressView().controlSize(.mini)
                Text("Syncing")
            } else if let date = synced.flatMap({ try? Date($0, strategy: .iso8601) }) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Live").help("Loaded from Notion \(date.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.rounded(11, .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.fill.tertiary, in: .capsule)
    }
}

/// A status or select value, coloured the way people usually mean it.
struct StatusTag: View {
    let name: String

    private var color: Color {
        let lower = name.lowercased()
        if ["done", "complete", "shipped", "closed", "published", "won"].contains(where: lower.contains) { return .green }
        if ["progress", "doing", "review", "active", "building", "writing"].contains(where: lower.contains) { return .blue }
        if ["block", "stuck", "risk", "lost"].contains(where: lower.contains) { return .red }
        if ["next", "todo", "to do", "ready", "planned", "backlog"].contains(where: lower.contains) { return .orange }
        return .gray
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name.isEmpty ? "No status" : name).lineLimit(1)
        }
        .font(.rounded(11.5, .semibold))
        .foregroundStyle(name.isEmpty ? .secondary : .primary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: .capsule)
    }
}

/// One column of the board: drop a row here to move it.
private struct BoardColumn: View {
    let name: String
    let rows: [Block.NotionRow]
    let columns: [String]
    let shown: [Block.NotionProp]
    let limit: Int
    let width: CGFloat?
    let id: UUID
    let model: RelayModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusTag(name: name)
                Text("\(rows.count)").font(.rounded(11, .semibold).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            ForEach(rows.prefix(limit)) { row in
                BoardCard(row: row, shown: shown, columns: columns, id: id, model: model)
            }
            if rows.count > limit {
                Text("+\(rows.count - limit) more").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            if rows.isEmpty {
                Text("Drop here").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .padding(8)
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
        .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quinary),
                    in: .rect(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.2), value: targeted)
        .onDrop(of: [.notionRow], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.notionRow.identifier) { data, _ in
                guard let data, let rowId = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in model.moveNotionRow(id, row: rowId, to: name) }
            }
            return true
        }
    }
}

private struct BoardCard: View {
    let row: Block.NotionRow
    let shown: [Block.NotionProp]
    let columns: [String]
    let id: UUID
    let model: RelayModel

    private var details: [String] {
        shown.compactMap { prop in
            let text = NotionBoard.display(row.values[prop.name] ?? "", type: prop.type)
            return text.isEmpty ? nil : (prop.type == "checkbox" ? "\(prop.name) ✓" : text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
            if !details.isEmpty {
                Text(details.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.55), in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(.rect)
        .onTapGesture(count: 2) { if let url = row.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) } }
        .onDrag {
            let provider = NSItemProvider()
            let data = Data(row.id.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.notionRow.identifier, visibility: .ownProcess) { done in
                done(data, nil)
                return nil
            }
            return provider
        } preview: {
            DragChip(symbol: "square.grid.3x2", title: row.title)
        }
        .contextMenu {
            Menu("Move to") {
                ForEach(columns, id: \.self) { name in
                    Button(name.isEmpty ? "No status" : name) { model.moveNotionRow(id, row: row.id, to: name) }
                }
            }
            if let url = row.url.flatMap(URL.init(string:)) {
                Button("Open in Notion") { NSWorkspace.shared.open(url) }
            }
        }
        .help("Drag to another column, double-click to open in Notion")
    }
}
