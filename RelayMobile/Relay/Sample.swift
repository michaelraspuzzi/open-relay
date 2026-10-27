import Foundation

/// Example cards for trying Relay before pairing, and for previews. Clearly labelled "Demo" in the app.
enum Sample {
    static let connectors: [MConnector] = [
        .init(id: "code", name: "Claude Code", logo: "claude", symbol: "", code: true),
        .init(id: "gmail", name: "Gmail", logo: "gmail", symbol: "", code: false),
        .init(id: "calendar", name: "Calendar", logo: "calendar", symbol: "", code: false),
        .init(id: "slack", name: "Slack", logo: "slack", symbol: "", code: false),
        .init(id: "notion", name: "Notion", logo: "notion", symbol: "", code: false),
        .init(id: "ideas", name: "Ideas", logo: "ideas", symbol: "lightbulb.max.fill", code: false),
    ]

    private static func m(_ fromUser: Bool, _ text: String, _ block: MBlock? = nil) -> MMessage {
        MMessage(id: UUID().uuidString, fromUser: fromUser, text: text, block: block)
    }

    static var cards: [MCard] {
        [
            MCard(id: "cal", connector: "calendar", name: "Calendar", subtitle: "All accounts", status: "idle", statusText: "4 actions today",
                  suggestions: ["Protect Friday morning", "Add travel buffers", "What's left today?"],
                  messages: [
                    m(true, "Give me two hours before Thursday's pitch with nothing in them."),
                    m(false, "Held 12:00–14:00 as focus time. Two invites tried to land there and got declined with a note."),
                    m(false, "", MBlock(type: "calendar", title: "Thursday, Oct 8", subtitle: "Focus held",
                                        events: [.init(time: "12:00", title: "Focus: final pass on the deck", detail: "2 invites declined"),
                                                 .init(time: "14:30", title: "Studio pitch", detail: "Studio · Room 2")])),
                    m(true, "Move the 1:1 with Sam to Friday."),
                    m(false, "Moved to Friday 10:00. Sam accepted."),
                  ]),
            MCard(id: "code", connector: "code", name: "Claude Code", subtitle: "⑂ relay-3f2a1c", status: "needs", statusText: "Needs you",
                  suggestions: ["Run the tests", "Merge to main", "Rebuild Relay"],
                  messages: [
                    m(true, "Fix the ⌘K palette sorting."),
                    m(false, "Found it. Rows were keyed by position, so SwiftUI reused the wrong row. I've switched them to stable ids."),
                    m(false, "", MBlock(type: "diff", title: "Overview.swift", removed: ["ForEach(rows.indices, id: \\.self) { i in"],
                                        added: ["ForEach(rows, id: \\.id) { row in", "    PaletteRow(row)"])),
                  ],
                  ask: MAsk(id: "demo-ask", tool: "Bash", detail: "swift build -c release", canAlways: true)),
            MCard(id: "mail", connector: "gmail", name: "Gmail", subtitle: "sam@example.com", status: "idle", statusText: "Ready",
                  suggestions: ["Make it warmer", "Triage the rest", "Find the contract"],
                  messages: [
                    m(true, "Reply to Dana. Yes to Thursday, but ask for 30 minutes, not an hour."),
                    m(false, "Here's the draft. It stays in Relay until you send it from the Mac."),
                    m(false, "", MBlock(type: "email", title: "Re: Thursday", subtitle: "To Dana Whitfield · draft",
                                        body: "Hi Dana, Thursday works. Could we keep it to 30 minutes? 2:00 or 2:30 both suit me.\n\nSam")),
                  ]),
            MCard(id: "slack", connector: "slack", name: "Slack", subtitle: "Acme Studio", status: "running", statusText: "Working",
                  suggestions: ["Draft a reply to Lena", "Pick a cover", "Mute #random"],
                  messages: [
                    m(true, "What did I miss in #design-review since this morning?"),
                    m(false, "", MBlock(type: "note", title: "#design-review", subtitle: "3 threads",
                                        points: ["Mira posted new cover options and wants a pick by end of day.",
                                                 "Jonas says tokens are final. Library v19 is live.",
                                                 "Lena asked if you're presenting Friday."])),
                  ],
                  activity: "Reading the last thread"),
            MCard(id: "ideas", connector: "ideas", name: "Ideas", subtitle: "Night shift", status: "idle", statusText: "3 actions today",
                  suggestions: ["Review branch 1", "Queue tonight's list", "Open the notes"],
                  messages: [
                    m(false, "Overnight I worked through three ideas from your list."),
                    m(false, "", MBlock(type: "checklist", title: "Last night",
                                        items: [.init(text: "Shortcuts intent \"Ask Relay\": branch ready to review", done: true),
                                                .init(text: "Slack channel cache: merged", done: true),
                                                .init(text: "Notes on the phone pairing flow, in Notion", done: true)])),
                  ]),
        ]
    }

    static func reply(to id: String, in link: MacLink) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            link.applyDemo { cards in
                guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
                cards[i].messages.append(MMessage(id: UUID().uuidString, fromUser: false,
                                                  text: "This is the demo, so nothing happened. Pair with your Mac and this card will do it for real."))
                cards[i].status = "idle"
                cards[i].statusText = "Ready"
            }
        }
    }
}
