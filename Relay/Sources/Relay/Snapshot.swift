import SwiftUI

/// RELAY_SNAPSHOT=/path.png renders sample blocks to an image and quits, so visuals can be checked without opening the window.
@MainActor
enum Snapshot {
    /// RELAY_SNAPSHOT_SET=meta: the Ideas and Discover blocks, the status pill and dropped-attachment chips.
    private static func meta(_ model: RelayModel) -> some View {
        let picks = Block(type: "connectors", title: "3 connectors to try", picks: [
            .init(name: "Linear", category: "Issue tracking", why: "You get Linear notification emails most days, and two repos reference LIN- issue ids.",
                  url: "https://linear.app/docs/mcp", setup: "claude.ai connector directory"),
            .init(name: "Figma", category: "Design", why: "Three meetings this week link Figma files; Relay could read frames into Code cards.",
                  url: "https://www.figma.com", setup: "claude mcp add --transport http figma https://mcp.figma.com/mcp")])
        let now = Block(type: "ideas", title: "4 things you could do now", ideas: [
            .init(title: "Reply to Config Berlin", why: "Their programme lead asked for your slot length on Tuesday; no reply yet.",
                  connector: "gmail", prompt: "Draft a reply…", minutes: 5),
            .init(title: "Prep for the 2pm review", why: "The deck in Drive changed since the invite went out.", connector: "drive", prompt: "…", minutes: 20)],
            night: false)
        let night = Block(type: "ideas", title: "Night shift · 2 tasks", ideas: [
            .init(title: "Add tests for the sidecar", why: "test.ts covers 3 of 7 ops; Relay changed a lot today.", connector: "code",
                  prompt: "…", minutes: 180, folder: NSHomeDirectory() + "/Projects/relay", priority: "high")],
            night: true)
        let card = Card(connector: Connector.find("gmail"), actionsToday: 12)
        return VStack(alignment: .leading, spacing: 16) {
            BlockView(block: picks, model: model)
            BlockView(block: now, model: model)
            BlockView(block: night, model: model)
            HStack(spacing: 12) {
                StatusPill(card: card)
                DragChip(symbol: "envelope", title: "Re: Keynote invitation") {}
                DragChip(symbol: "doc.richtext", title: "Headcount_Q1_plan.pdf")
                ConnectorIcon(connector: Connector.find("ideas"), size: 36)
                ConnectorIcon(connector: Connector.find("ideas"), size: 36, symbol: "moon.stars.fill")
                ConnectorIcon(connector: Connector.find("discover"), size: 36)
                Monogram(name: "Linear", size: 36)
            }
        }
        .frame(width: 760)
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=reply: the email a draft answers, as the card's strip and as the expanded pane.
    private static func reply() -> some View {
        let quote = Block.Quote(from: "Lena Vogt <programme@config.berlin>", date: "Tue, Oct 14 · 09:12",
                                body: "Hi Sam,\n\nWe'd love to have you open day two with a keynote on designing with AI. The slot is 20 minutes on the main stage, Oct 22 at 14:30.\n\nCould you confirm by Friday, and let us know if you need anything for the stage?\n\nBest,\nLena")
        return HStack(alignment: .top, spacing: 24) {
            ReplyQuote(quote: quote).frame(width: 490).padding(14)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
            ReplyQuote(quote: quote, expanded: true).frame(width: 330, height: 320)
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=todo: an editable to-do list, inline and opened full size.
    private static func todo(_ model: RelayModel) -> some View {
        let list = Block(type: "checklist", title: "To do — Saturday, Oct 3", items: [
            .init(text: "9:00 #1 thing block (till 11:30)", done: true), .init(text: "Reply to Lena re: keynote slot", done: false),
            .init(text: "Check the signed participation agreement", done: true), .init(text: "3:30 Tea, 29 Lyon St", done: false)])
        let message = Message(fromUser: false, text: "", block: list)
        let card = Card(connector: Connector.find("gmail"))
        card.messages = [message]
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            BlockView(block: list, model: model, card: card, messageId: message.id).frame(width: 540)
            ChecklistEditor(id: message.id, model: model, expanded: true).frame(width: 520).padding(30)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=work: a follow-ups list and a reviewed LinkedIn post.
    private static func work(_ model: RelayModel) -> some View {
        let list = Block(type: "followups", title: "7 follow-ups this week", followups: [
            .init(who: "Lena Vogt", about: "Confirm the day-two keynote slot by Friday", kind: "reply", source: "gmail", days: 4, prompt: ""),
            .init(who: "Sam Ortiz", about: "Asked for the sponsor deck in #hack-oct", kind: "reply", source: "slack", days: 1, prompt: ""),
            .init(who: "Priya Shah", about: "You said you'd send the Studio 45 floor plan", kind: "promise", source: "gmail", days: 8, prompt: ""),
            .init(who: "Wise and Sons", about: "Catering quote for Oct 24", kind: "waiting", source: "gmail", days: 3, prompt: ""),
            .init(who: "Dana Lee", about: "Intro to the Cornell team", kind: "reply", source: "gmail", days: 0, prompt: "", done: true)])
        let post = Block(type: "post", status: "reviewed", body: "Last Saturday 40 people walked into Studio 45 with an idea and walked out with a working prototype.\n\nOne team built a tool that reads lab notebooks out loud to blind researchers. They had never met before 9am.\n\nWhat would you build in 30 hours?",
                         title: "Hack recap", pillar: "projects",
                         scores: [.init(name: "Hook", score: 4), .init(name: "Voice", score: 5), .init(name: "Specifics", score: 4), .init(name: "Structure", score: 5), .init(name: "Close", score: 3)],
                         notes: ["Moved the blind-researchers story up: it's the moment people remember.", "Cut \"excited to share\" from the opener."])
        let a = Message(fromUser: false, text: "", block: list), b = Message(fromUser: false, text: "", block: post)
        let card = Card(connector: Connector.find("followups"))
        card.messages = [a, b]
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            BlockView(block: list, model: model, card: card, messageId: a.id).frame(width: 580)
            VStack(spacing: 12) {
                LinkedInStrip().frame(width: 540).background(.fill.quaternary, in: .rect(cornerRadius: 12))
                BlockView(block: post, model: model, card: card, messageId: b.id).frame(width: 560)
            }
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=substack: the Substack strip signed out and in, a new draft and a saved one opened full size.
    private static func substack(_ model: RelayModel) -> some View {
        var fresh = Block(type: "substack")
        fresh.title = "What 30 hours buys you"
        fresh.subtitle = "Notes from the Studio 45 hack"
        fresh.body = "Last Saturday 40 people walked into Studio 45 with an idea and walked out with a working prototype.\n\n## What they built\n\n- A tool that reads lab notebooks aloud\n- A **30-hour** prototype\n\nWhat would you build?"
        fresh.notes = ["Opened on the room, not the announcement.", "Cut the sponsor list to one line."]
        fresh.publication = "acme"
        fresh.channel = "Acme Studio"
        fresh.status = "draft"
        var saved = fresh
        saved.status = "saved"
        saved.postId = 123
        saved.url = "https://acme.substack.com/publish/post/123"
        saved.notes = nil
        let a = Message(fromUser: false, text: "", block: fresh), b = Message(fromUser: false, text: "", block: saved)
        let card = Card(connector: Connector.find("substack"))
        card.messages = [a, b]
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                SubstackStrip(model: model).frame(width: 560).background(.fill.quaternary, in: .rect(cornerRadius: 12))
                BlockView(block: fresh, model: model, card: card, messageId: a.id).frame(width: 580)
                HStack { ConnectorIcon(connector: Connector.find("substack"), size: 36); Spacer() }
            }
            SubstackEditor(id: b.id, model: model, expanded: true).frame(width: 620, height: 640)
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=note: an editable note, inline and opened full size.
    private static func note(_ model: RelayModel) -> some View {
        let note = Block(type: "note", body: "The keynote should open on the failure, not the demo.\nWhat did we get wrong about agents in 2025?\n\nAsk Lena whether the stage has a confidence monitor.",
                         title: "Thoughts on the keynote")
        let message = Message(fromUser: false, text: "", block: note)
        let card = Card(connector: Connector.find("gmail"))
        card.messages = [message]
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            BlockView(block: note, model: model, card: card, messageId: message.id).frame(width: 540)
            NoteEditor(id: message.id, model: model, expanded: true).frame(width: 520, height: 400).padding(30)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=slack: a Slack draft inline, opened full size, and once sent.
    private static func slack(_ model: RelayModel) -> some View {
        let draft = Block(type: "slack", status: "draft", body: "*Learning focus*\nThis week I'm going deep on evals: how we know an agent got better, not just different.",
                          channel: "#02-founders-log", channelId: "C0000000")
        var saved = draft
        saved.tag = "Saved to Slack"
        saved.url = "https://app.slack.com/client/T000/C0000000"
        var sent = draft
        sent.status = "sent"
        sent.url = saved.url
        let messages = [draft, saved].map { Message(fromUser: false, text: "", block: $0) }
        let card = Card(connector: Connector.find("slack"))
        card.messages = messages
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: draft, model: model, card: card, messageId: messages[0].id)
                BlockView(block: sent, model: model, card: card)
            }
            .frame(width: 540)
            SlackDraftEditor(id: messages[1].id, model: model, expanded: true).frame(width: 520, height: 380).padding(30)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=invite: a calendar invite draft inline, opened full size, and once created.
    private static func invite(_ model: RelayModel) -> some View {
        var draft = Block(type: "invite", status: "draft", to: "ana@config.berlin, jonas@config.berlin",
                          body: "Walk through the keynote run of show and the live build at the end.")
        draft.title = "Keynote run-through"
        draft.start = "2026-10-06T14:00:00"
        draft.end = "2026-10-06T14:45:00"
        draft.location = "Studio 2"
        draft.meet = true
        var created = draft
        created.status = "created"
        created.url = "https://www.google.com/calendar/event?eid=abc"
        let messages = [draft, draft].map { Message(fromUser: false, text: "", block: $0) }
        let card = Card(connector: Connector.find("calendar"))
        card.messages = messages
        model.cards.append(card)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: draft, model: model, card: card, messageId: messages[0].id)
                BlockView(block: created, model: model, card: card)
            }
            .frame(width: 540)
            VStack(spacing: 24) {
                InviteEditor(id: messages[1].id, model: model, expanded: true).frame(width: 560, height: 460).padding(30)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                MonthCalendar(selected: Invite.date(draft.start) ?? .now) { _ in }
                    .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=web: the Web card's results inline and opened full size, and its icon.
    private static func web(_ model: RelayModel) -> some View {
        let results = Block(type: "search", title: "Most recent Formula 1 Grand Prix winner",
                            summary: "George Russell won the Azerbaijan Grand Prix on September 26, holding off Max Verstappen by about 0.2 seconds in a race with several safety cars. It was his third win of the season.",
                            links: [.init(title: "Russell narrowly holds off Verstappen in chaotic Azerbaijan GP", url: "https://www.formula1.com/en/latest",
                                          note: "Official race report, Sept 26, 2026"),
                                    .init(title: "F1 2026 Azerbaijan Grand Prix race results", url: "https://www.the-race.com/formula-1/", note: "Full classification"),
                                    .init(title: "F1 2026 results from every race", url: "https://www.espn.com/f1/", note: "Season results; one entry conflicts with the live weekend"),
                                    .init(title: "Azerbaijan GP highlights", url: "https://www.youtube.com/")])
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                BlockView(block: results, model: model)
                ConnectorIcon(connector: Connector.find("web"), size: 36)
            }
            .frame(width: 600)
            SearchBlock(block: results, model: model, expanded: true).frame(width: 640, alignment: .leading)
                .padding(30).background(.white, in: .rect(cornerRadius: 16))
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    /// RELAY_SNAPSHOT_SET=five: a meeting brief, a live Notion board and table, the undo bar, the @ list and a pasted screenshot.
    private static func five(_ model: RelayModel) -> some View {
        let brief = Block(type: "brief", title: "Keynote run-through with Config Berlin", url: "https://meet.google.com/abc-defg-hij",
                          when: "Today · 2:30–3:00 PM", summary: "Last check before Oct 22: they want the final slot length and your A/V needs.",
                          attendees: [.init(name: "Lena Vogt", email: "programme@config.berlin", role: "Programme lead, Config Berlin",
                                            about: "Asked on Tuesday whether you can stretch to 30 minutes; still waiting on your answer.", source: "inbox"),
                                      .init(name: "Tomás Reyes", role: "Stage producer", about: "Runs A/V for the main stage; spoke at Figma Config 2024 on live demos.",
                                            source: "web", link: "https://example.com")],
                          threads: [.init(subject: "Re: Keynote invitation", from: "Lena", date: "Tue", gist: "Slot length still open.")],
                          points: ["Confirm 30 minutes with a live build at the end", "Ask for a second confidence monitor", "Share the deck by Oct 18"],
                          links: [.init(title: "Keynote deck", url: "https://docs.google.com")])
        let props: [Block.NotionProp] = [.init(name: "Status", type: "status", options: ["Not started", "In progress", "Done"]),
                                         .init(name: "Due", type: "date"), .init(name: "Owner", type: "people"), .init(name: "Shipped", type: "checkbox")]
        let rows: [Block.NotionRow] = [
            .init(id: "1", title: "Speaker bio for Config", values: ["Status": "Done", "Due": "2026-10-10", "Owner": "Sam", "Shipped": "true"]),
            .init(id: "2", title: "Keynote deck v2", values: ["Status": "In progress", "Due": "2026-10-18", "Owner": "Sam", "Shipped": "false"]),
            .init(id: "3", title: "Live build rehearsal", values: ["Status": "Not started", "Due": "2026-10-20", "Shipped": "false"]),
            .init(id: "4", title: "Book travel to Berlin", values: ["Status": "In progress", "Due": "2026-10-12", "Shipped": "false"])]
        var board = Block(type: "notion", title: "Config Berlin prep", url: "https://notion.so")
        board.groupBy = "Status"; board.props = props; board.rows = rows; board.synced = Date.now.formatted(.iso8601)
        var table = board
        table.view = "table"
        let card = Card(connector: Connector.find("notion"))
        let messages = [board, table].map { Message(fromUser: false, text: "", block: $0) }
        card.messages = messages
        model.cards.append(card)
        model.focusedId = model.cards.first?.id
        model.draft = "@c"
        model.heldSends = [HeldSend(kind: .draft(UUID()), title: "Sending to programme@config.berlin", connector: Connector.find("gmail"),
                                    deadline: .now + 6)]
        let shot = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: rect, angle: 30); return true
        }
        let image = Paste.attachment(for: shot)!
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: brief, model: model)
                UndoBar(model: model)
                HStack(alignment: .bottom, spacing: 14) {
                    MentionList(model: model)
                    ImageChip(attachment: image) {}
                    ImageChip(attachment: image, size: 90)
                }
            }
            .frame(width: 580)
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: board, model: model, card: card, messageId: messages[0].id)
                BlockView(block: table, model: model, card: card, messageId: messages[1].id)
            }
            .frame(width: 640)
        }
        .padding(30)
        .background(Color(white: 0.93))
    }

    static func runIfRequested(model: RelayModel) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["RELAY_SNAPSHOT"] else { return false }
        let calendar = Block(type: "calendar", date: "Wednesday, Oct 22", tag: "Focus held", events: [
            .init(time: "12:00", title: "Focus — final pass on the deck", detail: "Declines on · 2 invites bounced"),
            .init(time: "14:30", title: "Keynote — Designing with AI", detail: "Config Berlin · Main stage")])
        let email = Block(type: "email", status: "draft", to: "programme@config.berlin", subject: "Re: Keynote invitation — Oct 22",
                          body: "Happy to join. One ask: could we stretch the slot to 30 minutes? The material lands better with a short live build at the end.")
        let file = Block(type: "file", name: "Headcount_Q1_plan.pdf", kind: "PDF", detail: "Attached · 240 KB")
        let checklist = Block(type: "checklist", title: "Ship the design system", items: [.init(text: "Publish tokens", done: true), .init(text: "Update icon set", done: false)])
        let diff = Block(type: "diff", file: NSHomeDirectory() + "/Documents/app/Sources/Composer.swift", before: "let radius = 24", after: "let radius = 26\nlet glass = true")
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: calendar, model: model)
                BlockView(block: email, model: model)
                BlockView(block: file, model: model)
            }
            VStack(alignment: .leading, spacing: 14) {
                BlockView(block: checklist, model: model)
                BlockView(block: diff, model: model)
                TodoStrip(todos: [Todo(content: "Read the code", status: "completed", activeForm: ""),
                                  Todo(content: "Write the fix", status: "in_progress", activeForm: "Writing the fix"),
                                  Todo(content: "Run tests", status: "pending", activeForm: "")])
                ToastView(toast: CrossToast(connector: Connector.find("calendar"), title: "Calendar",
                                            detail: "From Gmail · Create event · Hold Oct 21–23", target: nil))
            }
        }
        .frame(width: 1180)
        .padding(30)
        .background(Color(white: 0.93))
        let set = ProcessInfo.processInfo.environment["RELAY_SNAPSHOT_SET"]
        let renderer = ImageRenderer(content: set == "meta" ? AnyView(meta(model)) : set == "reply" ? AnyView(reply()) : set == "todo" ? AnyView(todo(model)) : set == "note" ? AnyView(note(model)) : set == "work" ? AnyView(work(model)) : set == "slack" ? AnyView(slack(model)) : set == "five" ? AnyView(five(model)) : set == "invite" ? AnyView(invite(model)) : set == "web" ? AnyView(web(model)) : set == "substack" ? AnyView(substack(model)) : AnyView(view))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        return true
    }
}
