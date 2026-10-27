import AppKit
import LinkPresentation
import SwiftUI
import WebKit

/// A rich result rendered inside a thread: what the agent passed to a relay show_* tool, or a code diff.
struct Block: Codable, Equatable {
    struct Event: Codable, Equatable { var time: String; var title: String; var detail: String? }
    struct Item: Codable, Equatable { var text: String; var done: Bool }
    /// A connector the Discover card recommends.
    struct Pick: Codable, Equatable { var name: String; var category: String; var why: String; var url: String?; var setup: String? }
    /// Something the Ideas card suggests, runnable in one card.
    struct Idea: Codable, Equatable, Hashable { var title: String; var why: String; var connector: String; var prompt: String; var minutes: Double; var folder: String?
        /// "high" when it's one of the most important things on your plate right now.
        var priority: String? }
    /// The email a draft answers, shown above it.
    struct Quote: Codable, Equatable { var from: String; var date: String?; var body: String }
    /// Meeting prep: someone coming, an email thread that bears on it, a doc to have open.
    struct Attendee: Codable, Equatable { var name: String; var email: String?; var role: String?; var about: String; var source: String?; var link: String? }
    struct BriefThread: Codable, Equatable { var subject: String; var from: String?; var date: String?; var gist: String }
    /// A doc to have open (Meeting Prep) or a source the Web card used, with what it adds.
    /// Something the user owes someone, promised, or is waiting on (Follow-ups), with the instruction that acts on it.
    struct FollowUp: Codable, Equatable { var who: String; var about: String; var kind: String; var source: String; var days: Int
        var link: String?; var prompt: String; var done: Bool? }
    /// A post's feedback: a 1–5 score per criterion, and what changed and why.
    struct Score: Codable, Equatable { var name: String; var score: Int }
    struct LinkItem: Codable, Equatable { var title: String; var url: String; var note: String? = nil }
    /// A live Notion database: its properties (with status/select options) and rows, flattened to text.
    struct NotionProp: Codable, Equatable { var name: String; var type: String; var options: [String]? }
    struct NotionRow: Codable, Equatable, Identifiable { var id: String; var url: String?; var title: String; var values: [String: String] }

    var type: String
    // calendar
    var date: String?
    var tag: String?
    var events: [Event]?
    // email
    var status: String?
    var to: String?
    var from: String?
    var subject: String?
    var body: String?
    /// A reply's place in Gmail: the thread it goes into and, when known, the Message-ID header it answers.
    var threadId: String?
    var inReplyTo: String?
    var replyTo: Quote?
    // slack (also status, body, replyTo, url): where the message goes, as shown and as Slack's id, and the thread it answers
    var channel: String?
    var channelId: String?
    var threadTs: String?
    // invite (also title, to as guests, location, body as notes, status, tag, url): local ISO times, and whether to add Google Meet
    var start: String?
    var end: String?
    var meet: Bool?
    // file
    var name: String?
    var kind: String?
    var detail: String?
    var location: String?
    // link, checklist, note (also body)
    var title: String?
    var url: String?
    var items: [Item]?
    // diff
    var file: String?
    var before: String?
    var after: String?
    // connectors (Discover), ideas (Ideas)
    var picks: [Pick]?
    var ideas: [Idea]?
    var night: Bool?
    // drawing (Excalidraw element skeleton, already resolved; see Drawing.swift)
    var elements: String?
    // brief (Meeting Prep; also title, url, location); search (Web: title is the query, summary the answer, links the sources)
    var when: String?
    var summary: String?
    var attendees: [Attendee]?
    var threads: [BriefThread]?
    var points: [String]?
    var links: [LinkItem]?
    // notion (live database; also title, url): which data source, through which server's tools, and how to show it
    var dataSourceId: String?
    var toolPrefix: String?
    var groupBy: String?
    var columns: [String]?
    var props: [NotionProp]?
    var rows: [NotionRow]?
    /// When the rows were last loaded from Notion (ISO 8601), and "board" / "table" if the user switched views.
    var synced: String?
    var view: String?
    // followups (Follow-ups; also title)
    var followups: [FollowUp]?
    // post (LinkedIn; also title, body, status: draft / reviewed / opened / posted, date: when it was posted)
    var pillar: String?
    var scores: [Score]?
    var notes: [String]?
    // substack (also title, body as Markdown, notes, url as the editor link, synced as the draft's edit time when read,
    // channel as the publication's name, status: draft / saved): which publication and, once saved, which draft
    var subtitle: String?
    var publication: String?
    var postId: Int?

    static func decode(_ object: Any?) -> Block? {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Block.self, from: data)
    }

    /// Diff block from a finished Edit / MultiEdit / Write call.
    static func diff(tool: String, input: [String: Any]) -> Block? {
        guard let path = input["file_path"] as? String else { return nil }
        switch tool {
        case "Edit":
            return Block(type: "diff", file: path, before: input["old_string"] as? String ?? "", after: input["new_string"] as? String ?? "")
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return Block(type: "diff", file: path,
                         before: edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n…\n"),
                         after: edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n…\n"))
        case "Write":
            return Block(type: "diff", file: path, before: "", after: input["content"] as? String ?? "")
        default:
            return nil
        }
    }

    var opensPage: Bool { !["file", "image", "connectors", "ideas"].contains(type) }

    /// Blocks that hold their own controls (an editable draft, a live board): the thread doesn't make them one big button.
    var isInteractive: Bool { type == "notion" || type == "brief" || type == "search" || type == "followups" || type == "post" || type == "substack" }

    var symbol: String {
        switch type {
        case "calendar": "calendar"
        case "invite": "calendar.badge.plus"
        case "email": "envelope"
        case "slack": "number"
        case "file": "doc"
        case "image": "photo"
        case "link": "link"
        case "checklist": "checklist"
        case "note": "note.text"
        case "followups": "arrowshape.turn.up.left.2"
        case "post": "text.bubble"
        case "substack": "newspaper"
        case "diff": "chevron.left.forwardslash.chevron.right"
        case "drawing": "scribble.variable"
        case "connectors": "puzzlepiece.extension"
        case "ideas": "lightbulb"
        case "brief": "person.2.wave.2"
        case "search": "globe"
        case "notion": "square.grid.3x2"
        default: "square.on.square"
        }
    }

    /// A short name, for drag chips and page titles.
    var label: String {
        switch type {
        case "email": subject ?? "Email"
        case "slack": channel.map { "Message in \($0)" } ?? "Slack message"
        case "calendar": date ?? "Calendar"
        case "invite": title.flatMap { $0.isEmpty ? nil : $0 } ?? "Invite"
        case "file": name ?? "File"
        case "diff": URL(fileURLWithPath: file ?? "").lastPathComponent
        default: title ?? url ?? type.capitalized
        }
    }

    /// The block as plain text: what another card's agent reads when you drop it there, and what other apps get.
    var plainText: String {
        switch type {
        case "email":
            return [status.map { "Email (\($0))" }, from.map { "From: \($0)" }, to.map { "To: \($0)" },
                    subject.map { "Subject: \($0)" }, body.map { "\n\($0)" },
                    replyTo.map { "\nIn reply to \($0.from)\($0.date.map { " (\($0))" } ?? ""):\n\($0.body)" }].compactMap { $0 }.joined(separator: "\n")
        case "slack":
            return [status.map { "Slack message (\($0))" }, channel.map { "In: \($0)" }, body.map { "\n\($0)" }, url,
                    replyTo.map { "\nIn reply to \($0.from)\($0.date.map { " (\($0))" } ?? ""):\n\($0.body)" }].compactMap { $0 }.joined(separator: "\n")
        case "calendar":
            let lines = (events ?? []).map { "\($0.time) \($0.title)" + ($0.detail.map { " (\($0))" } ?? "") }
            return ([date ?? "Calendar"] + lines).joined(separator: "\n")
        case "invite":
            return [status.map { "Calendar invite (\($0))" }, title, Invite.when(start, end), to.map { "Guests: \($0)" },
                    location.map { "Where: \($0)" }, meet == true ? "With Google Meet" : nil, body.map { "\n\($0)" }, url]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        case "file":
            return [name, kind, detail, location].compactMap { $0 }.joined(separator: " · ")
        case "image":
            return ["Image: " + (title ?? "generated image"), detail.map { "Prompt: \($0)" }, location].compactMap { $0 }.joined(separator: "\n")
        case "link":
            return [title, url, detail].compactMap { $0 }.joined(separator: "\n")
        case "checklist":
            return ([title ?? "Checklist"] + (items ?? []).map { ($0.done ? "[x] " : "[ ] ") + $0.text }).joined(separator: "\n")
        case "followups":
            return ([title ?? "Follow-ups"] + (followups ?? []).map { ($0.done == true ? "[x] " : "[ ] ") + "\($0.who): \($0.about) (\($0.days)d, \($0.source))" }).joined(separator: "\n")
        case "post":
            return ["LinkedIn post" + (status.map { " (\($0))" } ?? ""), title, body].compactMap { $0 }.joined(separator: "\n\n")
        case "substack":
            return ["Substack draft" + (channel.map { " for \($0)" } ?? ""), title, subtitle, body, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "note":
            return [title, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "diff":
            return "Change to \(file ?? "a file"):\n--- before\n\(before ?? "")\n+++ after\n\(after ?? "")"
        case "drawing":
            return title ?? "An Excalidraw drawing"
        case "connectors":
            return ([title ?? "Connectors"] + (picks ?? []).map { "\($0.name) (\($0.category)): \($0.why)" }).joined(separator: "\n")
        case "ideas":
            return ([title ?? "Ideas"] + (ideas ?? []).map { "\($0.title): \($0.why)" }).joined(separator: "\n")
        case "brief":
            var lines = ["Meeting prep: \(title ?? "Meeting")" + (when.map { " · \($0)" } ?? "")]
            if let summary { lines.append(summary) }
            lines += (attendees ?? []).map { "- \($0.name)" + ($0.role.map { " (\($0))" } ?? "") + ": \($0.about)" }
            if let points, !points.isEmpty { lines.append("To cover:\n" + points.map { "- " + $0 }.joined(separator: "\n")) }
            return lines.joined(separator: "\n")
        case "search":
            var lines = [title ?? "Web search"]
            if let summary { lines.append(summary) }
            lines += (links ?? []).map { "- \($0.title): \($0.url)" }
            return lines.joined(separator: "\n")
        case "notion":
            let group = groupBy
            let lines = (rows ?? []).map { row in
                "- \(row.title)" + (group.flatMap { row.values[$0] }.map { " [\($0)]" } ?? "")
            }
            return ([(title ?? "Notion database") + (url.map { " · \($0)" } ?? "")] + lines).joined(separator: "\n")
        default:
            return title ?? type
        }
    }
}

// MARK: - Inline views

struct BlockView: View {
    let block: Block
    let model: RelayModel
    /// The card the block is in, for blocks with buttons (Discover's Set up).
    var card: Card? = nil
    /// The message holding the block; an email or Slack draft, a to-do list or a note with one is editable in place.
    var messageId: UUID? = nil

    private var wide: Bool { block.type == "connectors" || block.type == "ideas" }

    var body: some View {
        HStack {
            if block.type == "email", block.status == "draft", let messageId {
                DraftEditor(id: messageId, model: model)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .contentShape(.rect(cornerRadius: 16))
                    .contextMenu { draftMenu(messageId) }
                Spacer(minLength: 40)
            } else if block.type == "slack", block.status == "draft", let messageId {
                SlackDraftEditor(id: messageId, model: model)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .contentShape(.rect(cornerRadius: 16))
                    .contextMenu { draftMenu(messageId) }
                Spacer(minLength: 40)
            } else if block.type == "invite", block.status == "draft", let messageId {
                InviteEditor(id: messageId, model: model)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .contentShape(.rect(cornerRadius: 16))
                    .contextMenu { draftMenu(messageId) }
                Spacer(minLength: 40)
            } else if block.type == "notion", let messageId {
                NotionBoard(id: messageId, model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
            } else if block.type == "brief" {
                BriefBlock(block: block, model: model)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .onDrag { Drop.provider(for: block, from: card) } preview: { DragChip(symbol: block.symbol, title: block.label) }
                Spacer(minLength: 40)
            } else if block.type == "search" {
                SearchBlock(block: block, model: model)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .onDrag { Drop.provider(for: block, from: card) } preview: { DragChip(symbol: block.symbol, title: block.label) }
                Spacer(minLength: 40)
            } else if block.type == "checklist", let messageId {
                ChecklistEditor(id: messageId, model: model)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                Spacer(minLength: 40)
            } else if block.type == "followups", let messageId {
                FollowupsBlock(id: messageId, model: model)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                Spacer(minLength: 40)
            } else if block.type == "post", let messageId {
                PostEditor(id: messageId, model: model)
                    .frame(maxWidth: 540, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                Spacer(minLength: 40)
            } else if block.type == "substack", let messageId {
                SubstackEditor(id: messageId, model: model)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                Spacer(minLength: 40)
            } else if block.type == "note", let messageId {
                NoteEditor(id: messageId, model: model)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                Spacer(minLength: 40)
            } else {
                standard
            }
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    /// Right-click a draft: open it full size, or throw it away in Relay (the card stays).
    @ViewBuilder private func draftMenu(_ id: UUID) -> some View {
        Button("Expand") { model.expandDraft(id) }
        Divider()
        Button("Discard Draft", role: .destructive) { model.discardDraft(id) }
    }

    @ViewBuilder private var standard: some View {
            content
                .frame(maxWidth: wide ? .infinity : (block.type == "link" ? 360 : 520), alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                .contentShape(.rect(cornerRadius: 16))
                .onTapGesture { if !wide { model.openBlock(block) } }
                .onDrag { Drop.provider(for: block, from: card) } preview: { DragChip(symbol: block.symbol, title: block.label) }
                .help(wide ? "" : (block.opensPage ? "Open, or drag onto another card" : "Open file, or drag onto another card"))
            if !wide { Spacer(minLength: 40) }
    }

    @ViewBuilder private var content: some View {
        switch block.type {
        case "connectors": ConnectorPicksBlock(block: block, model: model, card: card)
        case "ideas": IdeasBlock(block: block, model: model)
        case "calendar": CalendarBlock(block: block, limit: 4)
        case "invite": InviteBlock(block: block, lines: 3)
        case "email": EmailBlock(block: block, lines: 3)
        case "slack": SlackBlock(block: block, lines: 4)
        case "file": FileBlock(block: block)
        case "image": ImageBlock(block: block)
        case "link": LinkBlock(block: block, model: model)
        case "checklist": ChecklistBlock(block: block, limit: 6)
        case "note": NoteBlock(block: block, lines: 8)
        case "diff": DiffBlock(block: block, limit: 12)
        case "drawing": DrawingBlock(block: block)
        default: Text(block.title ?? block.type).padding(14)
        }
    }
}

struct CalendarBlock: View {
    let block: Block
    var limit = Int.max

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(block.date ?? "Today").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if let tag = block.tag {
                    Text(tag).font(.rounded(11, .semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.14), in: .capsule)
                }
            }
            ForEach(Array((block.events ?? []).prefix(limit).enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 12) {
                    Text(event.time).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.accentColor).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 13, weight: .medium))
                            if let detail = event.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        Spacer(minLength: 0)
                    }
                    .background(.fill.tertiary)
                    .clipShape(.rect(cornerRadius: 7, style: .continuous))
                }
            }
            if let more = block.events?.count, more > limit {
                Text("+\(more - limit) more").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 76)
            }
        }
        .padding(14)
    }
}

struct EmailBlock: View {
    let block: Block
    var lines: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((block.status ?? "email").uppercased()).font(.rounded(10.5, .bold)).kerning(0.8)
                    .foregroundStyle(block.status == "sent" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Spacer()
                if let to = block.to { Text("to \(to)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                else if let from = block.from { Text("from \(from)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(block.subject ?? "").font(.system(size: 13.5, weight: .semibold))
            Text(block.body ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(lines)
                .textSelection(.enabled)
        }
        .padding(14)
    }
}

/// A Slack message that's been sent (or found): where it went, the text, and a way back to it in Slack.
struct SlackBlock: View {
    let block: Block
    var lines: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text((block.status ?? "message").uppercased()).font(.rounded(10.5, .bold)).kerning(0.8)
                    .foregroundStyle(block.status == "sent" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Spacer()
                if let channel = block.channel { Text("in \(channel)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                if let url = block.url.flatMap(URL.init(string:)) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.system(size: 12)) }
                        .foregroundStyle(.secondary).help("Open in Slack")
                }
            }
            if let quote = block.replyTo { ReplyQuote(quote: quote).padding(.vertical, 2) }
            Text(block.body ?? "").font(.system(size: 12.5)).lineLimit(lines)
                .textSelection(.enabled)
        }
        .padding(14)
    }
}

struct FileBlock: View {
    let block: Block
    var body: some View {
        HStack(spacing: 10) {
            Text((block.kind ?? "file").prefix(4).uppercased()).font(.rounded(9.5, .heavy)).foregroundStyle(.secondary)
                .frame(width: 34, height: 40)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(block.name ?? "File").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(block.detail ?? block.kind ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

/// An image Codex generated: the picture itself with its caption. Click opens it in Preview; drag it anywhere as a PNG.
struct ImageBlock: View {
    let block: Block
    @State private var image: NSImage?

    private var url: URL? { block.location.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipped()
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(block.title ?? "Generated image").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .help(block.detail ?? "")
        .contextMenu {
            Button("Copy Image") {
                guard let image else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            Button("Show in Finder") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
        // Read off the main thread: a generated image is a few MB of PNG.
        .task(id: block.location) {
            guard let url, let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else { return }
            image = NSImage(data: data)
        }
    }
}

struct LinkBlock: View {
    let block: Block
    let model: RelayModel

    private var host: String { URL(string: block.url ?? "")?.host() ?? block.url ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                if let image = model.previewImages[block.url ?? ""] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "safari").font(.system(size: 26)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 170)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title ?? host).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(block.detail ?? host).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
        }
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .task(id: block.url) { await model.loadPreview(for: block.url) }
    }
}

struct ChecklistBlock: View {
    let block: Block
    var limit = Int.max

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = block.title { Text(title).font(.system(size: 13.5, weight: .semibold)) }
            ForEach(Array((block.items ?? []).prefix(limit).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    Text(item.text).font(.system(size: 13)).strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                }
            }
            if let count = block.items?.count, count > limit {
                Text("+\(count - limit) more").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

struct DiffBlock: View {
    let block: Block
    var limit = Int.max

    private var lines: [(String, Color?)] {
        let removed = (block.before ?? "").isEmpty ? [] : (block.before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { ("- " + $0, Color.red) }
        let added = (block.after ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { ("+ " + $0, Color.green) }
        return (removed + added).map { ($0.0, Optional($0.1)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: (block.before ?? "").isEmpty ? "doc.badge.plus" : "pencil.line").foregroundStyle(.secondary)
                Text(Connector.shortPath(block.file ?? "")).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(lines.filter { $0.1 == .green }.count) −\(lines.filter { $0.1 == .red }.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, line in
                    Text(line.0).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 1)
                        .background((line.1 ?? .clear).opacity(0.12))
                }
                if lines.count > limit {
                    Text("\(lines.count - limit) more lines").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Full page

/// A block opened full size over everything: the web page itself for links, the whole email, the full diff…
struct PageOverlay: View {
    let block: Block
    let model: RelayModel

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.25)).ignoresSafeArea()
                .onTapGesture { model.closePage() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { model.closePage() } label: {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                            .overlay(Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain).help("Close (Esc)")
                    Spacer()
                    Text(title).font(.rounded(12.5, .medium)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(.fill.tertiary, in: .capsule)
                    Spacer()
                    if let url = URL(string: block.url ?? ""), block.type == "link" {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                            .buttonStyle(.plain).help("Open in browser")
                    } else {
                        Color.clear.frame(width: 14, height: 1)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().opacity(0.5)
                page
            }
            .frame(maxWidth: 1100, maxHeight: .infinity)
            .glassCard(cornerRadius: 24)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 80).padding(.vertical, 50)
        }
    }

    /// The block as it is now: an editable to-do list or note may have changed since it was opened.
    private var live: Block { model.pageMessage.flatMap { model.draft($0) } ?? block }

    private var title: String {
        let block = live
        return switch block.type {
        case "link": block.url ?? ""
        case "email": block.subject ?? "Email"
        case "slack": block.label
        case "calendar": block.date ?? "Calendar"
        case "invite": block.label
        case "diff": Connector.shortPath(block.file ?? "")
        case "drawing": block.title ?? "Excalidraw"
        case "brief": "Meeting prep · " + (block.title ?? "")
        case "post": "LinkedIn · " + (block.title ?? "Post")
        case "followups": block.title ?? "Follow-ups"
        default: block.title ?? ""
        }
    }

    @ViewBuilder private var page: some View {
        switch block.type {
        case "link":
            if let url = URL(string: block.url ?? "") { WebPage(url: url) } else { Text("Invalid link").padding() }
        case "diff":
            ScrollView { DiffBlock(block: block).frame(maxWidth: .infinity, alignment: .leading) }
        case "drawing":
            ExcalidrawEditor(elements: block.elements ?? "[]",
                             dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        case "calendar":
            ScrollView { CalendarBlock(block: block).frame(maxWidth: 640).padding(30) }
        case "invite":
            ScrollView { InviteBlock(block: live).frame(maxWidth: 640, alignment: .leading).padding(30) }
        case "email":
            ScrollView { EmailBlock(block: block).frame(maxWidth: 720, alignment: .leading).padding(30) }
        case "slack":
            ScrollView { SlackBlock(block: live).frame(maxWidth: 720, alignment: .leading).padding(30) }
        case "search":
            ScrollView { SearchBlock(block: block, model: model, expanded: true).frame(maxWidth: 720, alignment: .leading).padding(34) }
        case "brief":
            ScrollView { BriefBlock(block: block, model: model, expanded: true).frame(maxWidth: 760, alignment: .leading).padding(34) }
        case "notion":
            Group {
                if let id = model.pageMessage { NotionBoard(id: id, model: model, expanded: true) } else { Text("This board isn't in a card anymore").foregroundStyle(.secondary) }
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case "checklist":
            ScrollView {
                Group {
                    if let id = model.pageMessage { ChecklistEditor(id: id, model: model, expanded: true) } else { ChecklistBlock(block: block) }
                }
                .frame(maxWidth: 640, alignment: .leading).padding(30)
            }
        case "followups":
            ScrollView {
                Group {
                    if let id = model.pageMessage { FollowupsBlock(id: id, model: model, expanded: true) } else { Text("These follow-ups aren't in a card anymore").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: 720, alignment: .leading).padding(30)
            }
        case "post":
            Group {
                if let id = model.pageMessage { PostEditor(id: id, model: model, expanded: true) } else { ScrollView { NoteBlock(block: block) } }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading).padding(30)
        case "substack":
            Group {
                if let id = model.pageMessage { SubstackEditor(id: id, model: model, expanded: true) } else { ScrollView { NoteBlock(block: block) } }
            }
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading).padding(30)
        case "note":
            Group {
                if let id = model.pageMessage { NoteEditor(id: id, model: model, expanded: true) } else { ScrollView { NoteBlock(block: block) } }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading).padding(30)
        default:
            ScrollView { ChecklistBlock(block: block).frame(maxWidth: 640, alignment: .leading).padding(30) }
        }
    }
}

struct WebPage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        // Google won't sign you in to Gmail from an embedded browser's user agent; Safari's works.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Link preview images via LinkPresentation.
enum Previews {
    @MainActor static func image(for urlString: String) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let item = metadata.imageProvider ?? metadata.iconProvider else { return nil }
        return await withCheckedContinuation { done in
            item.loadObject(ofClass: NSImage.self) { object, _ in
                nonisolated(unsafe) let image = object as? NSImage
                done.resume(returning: image)
            }
        }
    }
}
