# Relay

A native Mac surface for Claude: one glass card per connector in a swipeable carousel, one shared composer at the bottom. Runs on your installed, logged-in `claude` (no API key).

```bash
./make-app.sh && open ~/Applications/Relay.app   # the real app: Dock icon, Spotlight, own mic permission
swift run                                        # quick dev loop
```

| Do | How |
|---|---|
| Hide | Esc or the red light; click the Dock icon to bring Relay back |
| Next / previous card | Two-finger swipe, ← → (when the composer is empty), ⌘← ⌘→, or click a side card |
| Jump to a card | ⌘1 – ⌘9 |
| Overview grid (3 columns, scrolls) | Pinch out, or ⌘G; pinch in, Esc or click a card to go back |
| Switch or start a card by name | ⌘K, type, ↑ ↓, Return |
| Pick a workspace (Notion, Slack…) or folder (Claude Code) | Click the subtitle under the card name |
| Dictate | Click the waveform; click Done or the arrow when finished |
| Hide / minimize / focus mode | Red / yellow / green lights, top left |
| Ask the focused card | Type in the composer; the chip shows which card you're talking to |
| Quick replies | The three chips in each card's footer (rewritten by Haiku after every reply) |
| New card for the same connector | `+` in the card footer, or ⌘N |
| Close a card / all cards | ⌘W / ⌥⌘W, or right-click; with nothing open, ⌘K starts again |
| Open a block full size | Click it (links open as a web page, files open in their app); Esc closes |
| Code card task list and diffs | The "2 of 5" strip under the header; edits show as diffs, approvals preview the diff |
| Parallel code cards | Folder menu › New card in a git worktree (own branch `relay/<repo>-xxxxxx`) |
| Approve / deny a tool | ⌘↩ / ⌘⌫, or Always allow |
| Undo a send | Send (or approving an agent's send) waits 8 seconds first: Undo in the bar at the top, the draft's Undo button, or ⌘Z. Change the window with `defaults write org.openrelay.relay relay.undoSeconds 15` |
| Send to another card | Start with `@` (`@calendar hold 2h for this`): pick from the list with ↑ ↓ and Tab or Return. You stay where you are; that card gets this card's conversation as context and its answer comes back as a toast |
| Screenshots and files in the composer | ⌘V a screenshot (or copied files), or drop a picture. Pictures go to Claude as images |
| Meeting Prep | The Meeting Prep card preps your next meeting (or the one you name): attendees from Calendar, history from Gmail, a quick web search only when that's thin. The brief has a Join button and opens full size |
| Live Notion boards | Ask the Notion card to show a database: it loads straight from Notion as a board (by status) or a table. Drag cards between columns or tick checkboxes and it saves to Notion; it reloads when it's over 5 minutes old |
| Stop a running reply | Esc or the stop button |
| Drag and drop | Drop Finder files, text, or any block (email, calendar day, link…) onto a card, a grid cell, or the dock that replaces the page dots while you drag. The card focuses, the item waits in the composer with that card's verb ("Save this as a Notion page"), and Return sends it |
| Discover | The Discover card looks at your inbox, calendar, repos and Claude Code history, then recommends 3 connectors you don't have and why. Set up walks you through adding one |
| Ideas | The Ideas card suggests 3–5 things to do now, each with a Do it button that runs it in the right card. Switch to Night shift for 1–5 hour tasks; queue them with Tonight and they start at 11 PM (change it in the queue pill). Code tasks get their own git worktree and auto-accept edits there; nothing is sent or posted, and Relay keeps the Mac from idle-sleeping while work is queued |
| Codex | The Codex card runs OpenAI's Codex on your ChatGPT plan (the CLI inside ChatGPT.app, signed in there; no API key). Ask for an image and it appears in the card (click opens Preview, drag it anywhere as a PNG, right-click to copy). Ask it to do something in a Mac app and it uses Computer Use, asking once per app ("Allow Computer Use to use Finder?"). It starts in Relay's workspace; pick a folder from the subtitle |

The Dock icon follows the system appearance: with Appearance set to Auto it turns dark at sunset.

When one card changes something in another connector (Gmail creating a Calendar event), a toast appears top right, the other card gets a note, and its agent hears about it with your next message there.

## Layout
- `Sources/Relay/`: SwiftUI + AppKit app (`App.swift` window/keys/hotkey, `Model.swift` cards and events, `Connectors.swift` the default cards, `Glass.swift` Liquid Glass surfaces)
- `sidecar/`: Agent SDK bridge (`index.ts`), the Codex bridge (`codex.ts`, over `codex app-server`) and the end-to-end checks (`bun run test.ts`)
- State: `~/Library/Application Support/Relay/cards.json`. Each card's conversation is a Claude Code session, resumable with `claude --resume <id>`.

Never export `ANTHROPIC_API_KEY` in the shell that launches Relay, because it outranks your claude.ai login.
