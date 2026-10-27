import AppKit
import SwiftUI

/// Posts you've put on LinkedIn, kept as files in Relay's linkedin-posts folder,
/// so the weekly count survives closing cards. Marking a post posted writes one.
@MainActor @Observable
final class PostLog {
    static let shared = PostLog()
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Relay/linkedin-posts")

    private(set) var dates: [Date] = []
    var goal: Int {
        get { access(keyPath: \.goal); return max(1, UserDefaults.standard.object(forKey: "relay.linkedinGoal") as? Int ?? 3) }
        set { withMutation(keyPath: \.goal) { UserDefaults.standard.set(newValue, forKey: "relay.linkedinGoal") } }
    }

    private init() { load() }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        dates = files.filter { $0.pathExtension == "md" }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("---") else { return nil }
            let front = text.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: true).first ?? ""
            let fields = Dictionary(front.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }, uniquingKeysWith: { a, _ in a })
            guard fields["status"] == "posted", let day = fields["date"] else { return nil }
            return Self.day.date(from: day)
        }.sorted()
    }

    /// This calendar week's posts (weeks start on your system's first weekday).
    var thisWeek: Int {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return dates.filter { week.contains($0) }.count
    }

    var daysSinceLast: Int? {
        dates.last.map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0), to: Calendar.current.startOfDay(for: .now)).day ?? 0 }
    }

    /// Writes the post as posted today, in the skills' format (frontmatter, then the post).
    func record(title: String, body: String, pillar: String?) {
        let today = Self.day.string(from: .now)
        let slug = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6).joined(separator: "-")
        var file = Self.folder.appendingPathComponent("\(today)-\(slug.isEmpty ? "post" : slug).md")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = Self.folder.appendingPathComponent("\(today)-\(slug.isEmpty ? "post" : slug)-\(n).md"); n += 1
        }
        let text = "---\ntitle: \(title)\ndate: \(today)\nstatus: posted\npillar: \(pillar ?? "")\n---\n\n\(body)\n"
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        load()
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The LinkedIn card's strip: this week's posts against your goal, and how long since the last one.
struct LinkedInStrip: View {
    private var log: PostLog { PostLog.shared }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<max(log.goal, log.thisWeek), id: \.self) { index in
                    Circle().fill(index < log.thisWeek ? AnyShapeStyle(Color.linkedIn) : AnyShapeStyle(.fill.secondary))
                        .frame(width: 8, height: 8)
                }
            }
            Text("\(log.thisWeek) of \(log.goal) this week").font(.rounded(12, .semibold).monospacedDigit())
            Spacer()
            Text(last).font(.system(size: 12)).foregroundStyle(lastColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(.rect)
        .contextMenu {
            Picker("Weekly goal", selection: Binding(get: { log.goal }, set: { log.goal = $0 })) {
                ForEach(1...7, id: \.self) { Text("\($0) a week").tag($0) }
            }
            Button("Show Posts in Finder") { NSWorkspace.shared.open(PostLog.folder) }
        }
        .help("Right-click to change your weekly goal")
        .onAppear { log.load() }
    }

    private var last: String {
        switch log.daysSinceLast {
        case nil: "No posts yet"
        case 0?: "Posted today"
        case 1?: "Last post yesterday"
        case let days?: "Last post \(days) days ago"
        }
    }

    private var lastColor: Color {
        guard let days = log.daysSinceLast else { return .secondary }
        return days >= 7 ? .red : days >= 4 ? .orange : .secondary
    }
}

extension Color {
    static let linkedIn = Color(red: 0.04, green: 0.4, blue: 0.76)
}

/// A LinkedIn post you edit in place: the agent drafts it, Get feedback scores and revises it,
/// and Post on LinkedIn copies it and opens LinkedIn's composer with it filled in. You press Post there,
/// then mark it posted here, which counts toward your week.
struct PostEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    @FocusState private var editing: Bool

    private var block: Block { model.draft(id) ?? Block(type: "post") }
    private var body_: String { block.body ?? "" }
    private var card: Card? { model.locate(id)?.0 }
    private var words: Int { body_.split { $0.isWhitespace }.count }

    private var text: Binding<String> {
        Binding(get: { block.body ?? "" }, set: { value in model.editDraft(id) { $0.body = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 10) {
            HStack(spacing: 8) {
                Text("LINKEDIN POST").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                if let pillar = block.pillar, !pillar.isEmpty { pill(pillar.capitalized, .secondary) }
                statusPill
                Spacer()
                if !expanded {
                    Button { model.openBlock(block, messageId: id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open")
                }
            }
            TextEditor(text: text)
                .focused($editing)
                .font(.system(size: expanded ? 15 : 13))
                .lineSpacing(expanded ? 4 : 2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .frame(minHeight: expanded ? 320 : inlineHeight, maxHeight: expanded ? .infinity : inlineHeight)
                .overlay(alignment: .topLeading) {
                    if body_.isEmpty {
                        Text("Write your post…").font(.system(size: expanded ? 15 : 13)).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
            counts
            if let scores = block.scores, !scores.isEmpty { review(scores) }
            actions
        }
        .padding(expanded ? 0 : 14)
        .onChange(of: editing) { model.editingDraft = editing }
        .onDisappear { if editing { model.editingDraft = false } }
    }

    /// Inline, the post shows whole up to about 14 lines, then scrolls.
    private var inlineHeight: CGFloat {
        let lines = body_.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + 69) / 70) }
        return min(max(CGFloat(lines) * 18 + 12, 90), 270)
    }

    private var counts: some View {
        let good = (150...300).contains(words)
        return HStack(spacing: 10) {
            Label("\(words) words", systemImage: good ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(good ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .help("150–300 words reads best on LinkedIn")
            Text("\(body_.count) / 3,000").foregroundStyle(body_.count > 3000 ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        }
        .font(.system(size: 11.5).monospacedDigit())
        .labelStyle(.titleAndIcon)
    }

    private func review(_ scores: [Block.Score]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(Array(scores.enumerated()), id: \.offset) { _, score in
                    let color: Color = score.score >= 4 ? .green : score.score == 3 ? .orange : .red
                    HStack(spacing: 3) {
                        Text(score.name).foregroundStyle(.secondary)
                        Text("\(score.score)").fontWeight(.bold).foregroundStyle(color)
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.1), in: .capsule)
                }
            }
            ForEach(Array((block.notes ?? []).enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(note).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.system(size: expanded ? 13 : 12))
            }
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch block.status {
        case "reviewed": pill("Reviewed", .blue)
        case "opened": pill("In LinkedIn", .orange)
        case "posted": pill("Posted" + (block.date.map { " · \($0)" } ?? ""), .green)
        default: pill("Draft", .secondary)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { feedback() } label: {
                HStack(spacing: 5) {
                    if card?.running == true { ProgressView().controlSize(.mini) }
                    Text("Get feedback")
                }
            }
            .buttonStyle(.bordered)
            .disabled(card?.running ?? true || body_.isEmpty)
            .help("Score it on hook, voice, specifics, structure and close, and revise it")
            Button("Copy") { copy() }.buttonStyle(.bordered).disabled(body_.isEmpty)
            Spacer()
            if block.status == "opened" {
                Button("Not yet") { model.editDraft(id) { $0.status = "reviewed" } }.buttonStyle(.bordered)
                Button("I posted it") { markPosted() }.buttonStyle(.borderedProminent).tint(.green)
            } else if block.status != "posted" {
                Button { post() } label: { Label("Post on LinkedIn", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent).tint(.linkedIn)
                    .disabled(body_.isEmpty || body_.count > 3000)
                    .help("Copies the post and opens LinkedIn's composer with it; you press Post there")
            }
        }
        .controlSize(expanded ? .regular : .small)
    }

    private func feedback() {
        guard let card else { return }
        if expanded { model.closePage() }
        model.send("Get feedback on this post", to: card, prompt: """
        Give me feedback on this LinkedIn post as it stands now (I may have edited it since you showed it):

        \(body_)

        Score it, then call show_linkedin_post with your revised version (status "reviewed"), the scores, and \
        two to four notes on what you changed and why. Keep my wording wherever it already works.
        """)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body_, forType: .string)
    }

    private func post() {
        copy()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        let encoded = body_.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if let url = URL(string: "https://www.linkedin.com/feed/?shareActive=true&text=" + encoded) { NSWorkspace.shared.open(url) }
        model.editDraft(id) { $0.status = "opened" }
    }

    private func markPosted() {
        let today = PostLog.day.string(from: .now)
        PostLog.shared.record(title: block.title ?? String(body_.prefix(40)), body: body_, pillar: block.pillar)
        withAnimation(.snappy(duration: 0.25)) { model.editDraft(id) { $0.status = "posted"; $0.date = today } }
    }
}
