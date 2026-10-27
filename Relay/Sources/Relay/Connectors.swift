import Foundation

/// A connector a card is bound to. Every card runs the same `claude` (all your MCP servers load);
/// the system prompt scopes the agent to its connector, and to one account when there are several.
struct Connector: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let logo: String
    let model: String
    /// Lowercased substrings that mark an MCP server as one of this connector's accounts.
    let serverMatches: [String]
    let prompt: String
    let starters: [String]
    /// What dropping a file or block on this card offers to do, prefilled in the composer.
    var dropVerb = "Take a look at this"
    /// SF Symbol for cards with no platform logo (Discover, Ideas, Meeting Prep, Web).
    var symbol: String? = nil
    /// Task cards (Meeting Prep) do one job across other connectors: these start with the card, the rest stay in reach.
    var uses: [String] = []
    /// A Claude Code agent (~/.claude/agents/<name>.md) this card follows, so Claude Code and Relay share one copy of its instructions.
    var agent: String? = nil
    /// "codex": the card runs the user's Codex (ChatGPT sign-in, through `codex app-server`) instead of claude.
    var engine: String? = nil

    /// The agent file's instructions without its frontmatter, read fresh so edits apply from the card's next session.
    var agentInstructions: String? {
        guard let agent, let text = try? String(contentsOfFile: NSHomeDirectory() + "/.claude/agents/\(agent).md", encoding: .utf8) else { return nil }
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let workspace = NSHomeDirectory() + "/Library/Application Support/Relay/workspace"
    static let defaultFolder = NSHomeDirectory()

    static let shared = """
    You are one card in Relay, a Mac app where each card is a small chat for a single connector. \
    Your reply renders in a chat bubble, so keep it short: usually one to three sentences of plain, \
    conversational prose, with no headings, tables or bullet walls. Do the work, then report what \
    you did in the past tense, like a capable chief of staff. Ask before sending, deleting or \
    declining anything on the user's behalf.
    """

    var isCode: Bool { id == "code" }
    /// Codex: OpenAI's agent on the user's ChatGPT plan, with its own image generation and Computer Use.
    var isCodex: Bool { engine == "codex" }
    /// Cards that work in a folder you pick (Claude Code, Codex).
    var usesFolder: Bool { isCode || isCodex }
    var isDiscover: Bool { id == "discover" }
    var isIdeas: Bool { id == "ideas" }
    var isPrep: Bool { id == "prep" }
    var isFollowups: Bool { id == "followups" }
    var isLinkedIn: Bool { id == "linkedin" }
    var isSubstack: Bool { id == "substack" }
    /// Web: searches the web for you. Starts with no MCP servers; your connectors stay one use_connectors away.
    var isWeb: Bool { id == "web" }
    /// A card for one specific job across connectors (Meeting Prep), rather than one connector.
    var isTask: Bool { !uses.isEmpty }
    /// Discover and Ideas: Relay's own cards, which look across your connectors instead of acting in one.
    var isMeta: Bool { isDiscover || isIdeas }

    static let all: [Connector] = [
        Connector(id: "gmail", name: "Gmail", logo: "gmail", model: "sonnet", serverMatches: ["gmail"],
                  prompt: "You are the Gmail card.",
                  starters: ["What needs a reply", "Summarize today's inbox", "Find unread from this week"],
                  dropVerb: "Draft an email with this"),
        Connector(id: "calendar", name: "Calendar", logo: "calendar", model: "sonnet", serverMatches: ["calendar"],
                  prompt: "You are the Calendar card.",
                  starters: ["What's on today", "Find a free hour", "Check this week for conflicts"],
                  dropVerb: "Put this on my calendar"),
        Connector(id: "prep", name: "Meeting Prep", logo: "prep", model: "sonnet", serverMatches: [],
                  prompt: """
                  You are the Meeting Prep card: you get the user ready for a meeting. Unless they name one, prep the next \
                  meeting on their calendar that has other people in it (skip focus blocks and solo holds). Read the event: \
                  title, time, attendees, description, attached docs and video link. For each attendee who isn't the user, \
                  search their inbox for recent threads with that person and their company domain, and Slack too if you can. \
                  Only when that leaves you knowing little about someone (no thread, no role), do one or two quick web \
                  searches for their name with their company or email domain, and say in their entry that it came from the web. \
                  Never search the web about people from the user's own company. Then call show_meeting_brief once and reply \
                  with one short sentence. Ask before emailing or messaging anyone.
                  """,
                  starters: ["Prep my next meeting", "Prep today's meetings", "Who am I meeting this week"],
                  dropVerb: "Prep me for this meeting", symbol: "person.2.wave.2.fill", uses: ["calendar", "gmail"]),
        Connector(id: "followups", name: "Follow-ups", logo: "followups", model: "sonnet", serverMatches: [],
                  prompt: """
                  You are the Follow-ups card: you find what the user owes people and what they're waiting on, so nothing \
                  slips. Look back 14 days unless they say otherwise. Three kinds: "reply" (someone wrote to the user \
                  personally and is waiting for an answer), "promise" (the user said they'd do something, like "I'll send", \
                  "will follow up", "let me check", "by Friday", and no later message delivers it), and "waiting" (the user \
                  asked someone something 3+ days ago and got no answer). In Gmail, open each candidate thread and check \
                  in:sent: if the user wrote last, it isn't a "reply"; skip newsletters, notifications, receipts, invites and \
                  mass mail. In Slack, check DMs and mentions the user hasn't answered, and their own promises there. \
                  Then call show_followups once, most overdue first within each kind, at most 15. Each item's prompt is a \
                  complete instruction this card can act on later with no other context: who, the thread (subject, \
                  Gmail thread id or Slack channel and ts), what was asked or promised, and what to draft. When asked to act \
                  on one, draft it with show_email or show_slack_message (status "draft", with replyTo and the thread) and \
                  never send. Reply with one short sentence.
                  """,
                  starters: ["Who's waiting on me", "What did I promise this week", "Who should I nudge"],
                  dropVerb: "Follow up on this", symbol: "arrowshape.turn.up.left.2.fill", uses: ["gmail", "slack"]),
        Connector(id: "linkedin", name: "LinkedIn", logo: "linkedin", model: "opus", serverMatches: [],
                  prompt: """
                  You are the LinkedIn card: you help the user post on LinkedIn regularly about their work (stories \
                  about the people, projects and partners around them). Voice: like texting a smart friend about \
                  something exciting at work; lead with the human story, not the announcement; specific names, details \
                  and moments; short paragraphs with blank lines between; 150-300 words; at most 3 hashtags and one or two \
                  emoji, zero is fine; close with something that invites a real response, never "Agree?". Never open with \
                  "Excited to announce", "I'm humbled", "Thrilled" or "Hot take", and never use corporate words like \
                  leverage, synergy or ecosystem. Use the linkedin-draft and linkedin-review skills if you have them, but \
                  show drafts in Relay, not as files. \
                  To draft: if the user gives a topic, write it. If not, look at their last week (calendar meetings with \
                  people, sent mail, Slack, Notion) for three real stories worth posting, say them in one line each, and \
                  draft the strongest. Ask at most one question, only when a key fact is missing. Show every draft with \
                  show_linkedin_post (status "draft") and reply with one short sentence. \
                  For feedback: score the post 1-5 on Hook, Voice, Specifics, Structure and Close, fix what scores under 4, \
                  and call show_linkedin_post with the revised post (status "reviewed"), the scores and two to four notes \
                  on what changed and why. \
                  Never post to LinkedIn yourself: the user posts from the card. Only when asked, add a post to the \
                  Notion content calendar database they name, with status "Ready to post".
                  """,
                  starters: ["Draft a post from my week", "Three post ideas", "Review my draft"],
                  dropVerb: "Turn this into a LinkedIn post", symbol: "text.bubble.fill", uses: ["calendar", "gmail"]),
        Connector(id: "substack", name: "Substack", logo: "substack", model: "opus", serverMatches: [],
                  prompt: """
                  You are the Substack card: you help the user write and work on drafts for their Substack publications. \
                  They run more than one, so every substack_* tool takes the publication as they said it ("the studio one", \
                  a name, a subdomain) and matches it; call substack_publications when you need the list. Once they name \
                  a publication, keep using it for the rest of the conversation until they name another. If they haven't \
                  named one and it isn't clear, ask, listing their publications by name. \
                  To work on an existing draft, find it with substack_drafts, read it with substack_read_draft, and show \
                  your version with show_substack_draft passing its draftId and synced (its `updated`), so it saves over \
                  that draft. Keep every <!-- substack block … --> line where it is: those are images and embeds. For a \
                  new post, show it with show_substack_draft and no draftId. Write in the user's voice: load a writing-voice \
                  skill if one is listed, and match their earlier posts when you've read some. \
                  You never save, publish or schedule anything. The user edits the draft in the card, presses Save to \
                  Substack, and publishes from Substack. After showing a draft, reply with one short sentence. \
                  If a tool says they aren't signed in, Relay has shown a Sign in button: ask them to use it, then stop.
                  """,
                  starters: ["My latest drafts", "Draft a post from my week", "Tighten my newest draft"],
                  dropVerb: "Turn this into a Substack post"),
        Connector(id: "web", name: "Web", logo: "web", model: "sonnet", serverMatches: [],
                  prompt: """
                  You are the Web card: you search the web for the user. Whatever they type is something to look up, \
                  not a request for your own knowledge: run WebSearch (several focused queries for anything with more than \
                  one part), and open the best two or three pages with WebFetch when the snippets aren't enough to be sure. \
                  Prefer primary sources (the company, the paper, the docs) over aggregators, and say so when sources disagree \
                  or are old. Then call show_web_results once with the answer and the sources you actually used, and reply \
                  with one short sentence that adds what the card doesn't. For a follow-up, search again rather than guessing.
                  """,
                  starters: ["What's new in AI this week", "Today's top headlines", "Weather this weekend"],
                  dropVerb: "Search the web for this", symbol: "globe"),
        Connector(id: "memo", name: "Memo", logo: "memo", model: "opus", serverMatches: [],
                  prompt: """
                  You are the Memo card. Your instructions below are shared with Claude Code; in Relay, research and write \
                  the memo as they say, then show the saved page with show_file (kind "Memo", location its full path) and \
                  reply with one sentence: the thesis, plus at most one offer.
                  """,
                  starters: ["Pick a topic and write a memo", "Memo on a company", "Explain a mechanism"],
                  dropVerb: "Write a memo about this", symbol: "doc.text.fill", agent: "memo"),
        Connector(id: "slack", name: "Slack", logo: "slack", model: "sonnet", serverMatches: ["slack"],
                  prompt: "You are the Slack card.",
                  starters: ["Catch me up", "Any mentions today", "Draft a standup update"],
                  dropVerb: "Post this in Slack"),
        Connector(id: "notion", name: "Notion", logo: "notion", model: "sonnet", serverMatches: ["notion"],
                  prompt: "You are the Notion card. When the user wants to see or work through a database (a tracker, board, list or CRM), show it live with show_notion_database instead of listing its rows.",
                  starters: ["What changed recently", "Find a page", "Create a quick note"],
                  dropVerb: "Save this as a Notion page"),
        Connector(id: "crm", name: "CRM", logo: "crm", model: "sonnet", serverMatches: ["notion"],
                  prompt: """
                  You are the CRM card: the user's contacts live in a Notion database (ask which one the first time, then \
                  remember it for the conversation). If a Claude Code agent named crm exists, its instructions follow. Keep \
                  replies to a few short sentences, and when the user wants to see or work through the CRM, show it live \
                  with show_notion_database (grouped by its status or next-action property) instead of listing rows. \
                  For a scan, still report the short prioritized list.
                  """,
                  starters: ["Who should I follow up with", "Log a conversation", "Add a contact"],
                  dropVerb: "Log this in the CRM", symbol: "person.crop.rectangle.stack.fill", agent: "crm"),
        Connector(id: "drive", name: "Drive", logo: "drive", model: "sonnet", serverMatches: ["drive", "docs"],
                  prompt: "You are the Google Drive card. You can use Google Drive and Google Docs.",
                  starters: ["Recent files", "Find a doc", "Summarize a doc"],
                  dropVerb: "Save this to my Drive"),
        Connector(id: "excalidraw", name: "Excalidraw", logo: "excalidraw", model: "sonnet", serverMatches: ["excalidraw"],
                  prompt: """
                  You are the Excalidraw card: you sketch diagrams, flows, maps and explainers with the Excalidraw \
                  create_view tool (call read_me once first in a conversation). Relay shows every drawing as a card in \
                  the chat that the user can open and edit, so after drawing reply with one short sentence. To change a \
                  drawing, start from it with restoreCheckpoint and add or delete elements rather than redrawing.
                  """,
                  starters: ["Sketch a flowchart", "Diagram my week", "Map out a system"],
                  dropVerb: "Turn this into a diagram"),
        Connector(id: "code", name: "Claude Code", logo: "claude", model: "opus", serverMatches: [],
                  prompt: "You are the Claude Code card, working in this folder. For anything on the web (a site, a dashboard), you can use the user's Chrome with the claude-in-chrome tools.",
                  starters: ["What's in this folder", "Run the tests", "What changed recently"],
                  dropVerb: "Take a look at this"),
        Connector(id: "codex", name: "Codex", logo: "codex", model: "", serverMatches: [],
                  prompt: """
                  You are the Codex card. Besides code and the shell, you make images (generate a new one, or edit one the \
                  user attached or you made earlier in this thread) and you can use the user's Mac apps with Computer Use \
                  when a task needs an app's UI. After making an image, reply with one short sentence; Relay shows the image.
                  """,
                  starters: ["Make a wallpaper for my Mac", "What's open on my screen", "What's in this folder"],
                  dropVerb: "Take a look at this", engine: "codex"),
        Connector(id: "ideas", name: "Ideas", logo: "ideas", model: "sonnet", serverMatches: [],
                  prompt: """
                  You are the Ideas card. You suggest what the user could get done next, by reading (never changing) their calendar, inbox, Slack, Notion, Drive and recent Claude Code work. When asked for ideas, look around with read-only tools, then call show_ideas exactly once. Every idea must be concrete and grounded in something you actually saw; name it in `why`. Write each `prompt` so the target card can run it without asking anything. \
                  Before suggesting anything about an email thread, open the whole thread and search in:sent for it: \
                  if the user wrote the latest message, or replied after their last one, it's handled, so skip it. Skip it too \
                  if a draft reply is already waiting. Do the same for Slack threads the user already answered.
                  """,
                  starters: ["Ideas for right now", "Night shift ideas", "Something under 15 minutes"],
                  dropVerb: "What could I do with this?", symbol: "lightbulb.max.fill"),
        Connector(id: "discover", name: "Discover", logo: "discover", model: "sonnet", serverMatches: [],
                  prompt: """
                  You are the Discover card. You find MCP servers and claude.ai connectors the user doesn't have yet and would actually use. Look for evidence first: senders and tools in their inbox, calendar attendees' products, their repos and recent Claude Code prompts. Then search the MCP registry tools if you have them, otherwise the web, for official or well-maintained servers. Never recommend something already connected. Call show_connector_picks exactly once. When asked to set one up, give the exact steps; only run `claude mcp add` after the user says so.
                  """,
                  starters: ["Find 3 connectors for me", "Something for my repos", "What do power users add"],
                  dropVerb: "Which connector would help with this?", symbol: "sparkle.magnifyingglass"),
    ]

    static func find(_ id: String) -> Connector { all.first { $0.id == id } ?? all[0] }
    /// For ideas the agent routes to a card: unknown ids go to Claude Code, which can do most things.
    static func route(_ id: String) -> Connector { all.first { $0.id == id && !$0.isMeta } ?? find("code") }

    /// The MCP servers that are accounts of this connector, e.g. notion-personal and notion-work.
    func accounts(in servers: [String]) -> [String] {
        servers.filter { server in serverMatches.contains { server.lowercased().contains($0) } }
    }

    /// "notion-work" → "Work", "claude.ai Notion" → "Notion (claude.ai)", "plugin:slack:slack" → "Slack".
    static func accountName(_ server: String) -> String {
        if server.hasPrefix("claude.ai ") { return String(server.dropFirst(10)) + " (claude.ai)" }
        let last = server.split(whereSeparator: { ":-_".contains($0) }).last.map(String.init) ?? server
        let generic = ["mcp", "slack", "notion", "gmail", "calendar", "drive", "docs"]
        let parts = server.split(whereSeparator: { ":-_".contains($0) }).map(String.init)
        let specific = parts.first { !generic.contains($0.lowercased()) && $0 != "plugin" && $0 != "google" }
        return (specific ?? parts.first { $0 != "plugin" } ?? last).capitalized
    }

    /// Tools from server "plugin:slack:slack" are named mcp__plugin_slack_slack__* ("gmail-mcp" keeps its hyphen).
    static func toolPrefix(_ server: String) -> String {
        "mcp__" + server.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined() + "__"
    }

    /// The `claude` folders you've worked in most recently, newest first (from ~/.claude/projects).
    static func recentFolders(limit: Int = 12) -> [String] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [(String, Date)] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let newest = files.filter { $0.pathExtension == "jsonl" }
                .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
                .max { $0.1 < $1.1 }
            guard let (file, date) = newest, let cwd = firstCwd(in: file),
                  fm.fileExists(atPath: cwd), !cwd.hasPrefix(NSTemporaryDirectory()), !cwd.hasPrefix("/private/") else { continue }
            found.append((cwd, date))
        }
        var seen = Set<String>()
        return found.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    private static func firstCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 64_000), as: UTF8.self)
        for line in head.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cwd = obj["cwd"] as? String { return cwd }
        }
        return nil
    }

    static func shortPath(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}
