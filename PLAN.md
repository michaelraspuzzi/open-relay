# Relay — a native Mac surface for Claude agents

Working name: **Relay**. A floating, keyboard-first Mac app where every connector (Gmail, Calendar, Slack, Notion, Figma, a code repo…) is its own **mini chat card**. Claude acts *inside* each card, answers come back as rich **pages** (calendar day, email draft, kanban, diff, live preview), and the cards notify each other when one agent touches another's world. Claude Code sessions are first-class cards, so the same surface runs your coding agents.

Reference: Felix Haas's 44-second demo, "I built the multi-agent interface I wanted" (silent). The frame-by-frame notes below come from it.

---

## 1. What the video actually shows

| # | Element | Detail (measured off 1344pt-wide frames) | Frame |
|---|---|---|---|
| 1 | **Chromeless overlay** | No window chrome. Floats over the desktop (Finder stays frontmost in the menu bar), so it's a non-activating panel summoned on top of everything, like Spotlight. | all |
| 2 | **Horizontal card carousel** | Centre card ≈ 840×665pt (~63% of screen width), corner radius ≈ 28pt, dark translucent material. Neighbours peek ≈ 190pt from each edge, slightly smaller, dimmer and softer. | `01` |
| 3 | **Card header** | Connector icon + name + account/context subtitle ("Felix — Week 43", "felix@… — Primary"). Status pill top-right with a green dot: "1 conflict resolved", "3 threads waiting", "4 comments open", "6 actions today". Grabber handle centred at the top edge. | `01`,`02` |
| 4 | **Thread** | iMessage grammar: user = system-blue capsule on the right, assistant = ~8% white fill on the left. ~15pt SF Pro. Typing indicator is a three-dot bubble. | `02` |
| 5 | **Inline "pages" (rich blocks)** | Calendar day with a "Focus held" tag, email DRAFT card (subject, to, body), PDF attachment chip, Notion kanban (In review / columns), Figma component preview, website link preview with image + URL. | `01`,`02`,`05` |
| 6 | **Footer** | `+` on the left, 3 context-aware suggestion chips on the right ("Protect Thursday morning", "Move the board prep", "Add travel buffers"). The chips refresh after every turn. | `01`,`06` |
| 7 | **One shared composer** | Single pill at the bottom (~620×56pt). Left chip = the focused card's connector (icon + name), and it changes as you swipe. "Ask me anything". The round blue button is a **voice waveform when empty and morphs to a send arrow** once you type. | `01`,`02` |
| 8 | **Cross-agent toasts** | Top-right glass toast (~300×68pt, r≈18): connector icon, name, one-line summary ("Calendar · Blocked Monday from 09:00…", "Notion · Added the Q1 four-headcount…"). Fired when an action in one card lands in another connector. | `02`,`03` |
| 9 | **Grid overview** | Zooms out to a 3×2 grid of all cards (Exposé-style) with page dots underneath. Cards land as **empty skeletons first, then their content fades in** about 80ms later (a snapshot or lazy-render trick). Click one to zoom back in. | `03` |
| 10 | **Page expand** | Clicking a preview zooms it (matched geometry) into a full window with traffic lights and a URL bar (`aman-tokyo.lovable.app`). Everything behind it blurs and dims. | `04` |
| 11 | **Motion feel** | Card swipe settles in about 6–8 frames at 12fps (~0.5s) with no overshoot, so a critically damped spring. New messages fade and rise in. Nothing bounces playfully. It all feels physical and calm. | strips |

**Design principle to steal:** *one conversation per surface, one input for all of them.* Context comes from **where you are** (the focused card), not from what you type.

---

## 2. Product shape

```
Relay
├─ Cards (Threads)         one per connector or repo, persistent, swipeable
│   ├─ Connector card      Gmail, Calendar, Slack, Notion, Linear, Figma… (MCP servers)
│   ├─ Code card           a Claude Code session bound to a repo or worktree
│   └─ Scratch card        no connector, plain Claude
├─ Blocks → Pages          typed rich outputs inline; click to expand to a full page
├─ Composer                one input, scoped to the focused card; voice + text
├─ Grid                    overview of every card with live status (the agent control room)
└─ Toasts / Inbox          cross-card events + "needs you" (approvals, questions)
```

### Interaction model (keyboard first, Mac-native)
| Action | Shortcut / gesture |
|---|---|
| Summon / hide | global hotkey `⌥Space` (configurable) |
| Next / prev card | `⌘→ / ⌘←`, two-finger swipe, `⌃Tab` |
| Jump to card | `⌘1…9` |
| Grid overview | `⌘G`, pinch in, or 3-finger swipe up |
| Focus composer | just start typing |
| Retarget a message | type `@calendar …` to send to another card without leaving this one |
| Push-to-talk | hold `fn` (or the waveform button) |
| Interrupt agent | `Esc` (while running) |
| Approve / deny pending tool | `⌘↩ / ⌘⌫` |
| Expand block to page | `Space` (Quick Look style) or click |
| New card | `⌘N` → connector picker |

---

## 3. Architecture

```
┌────────────── Relay.app (Swift, SwiftUI + AppKit) ─────────────┐
│ RelayPanel (NSPanel, non-activating, full-screen overlay)      │
│  ├─ CarouselView / GridView / PageView (SwiftUI)              │
│  ├─ Composer (glass)  ── Speech (SFSpeechRecognizer/on-device) │
│  └─ ToastCenter                                                 │
│ AppModel (@Observable) ── ThreadStore (SQLite via GRDB)         │
│        │  JSON-lines over stdio                                 │
└────────┼────────────────────────────────────────────────────────┘
         ▼
┌──── relay-agent (bundled sidecar, Claude Agent SDK, TS → bun --compile) ───┐
│ One SDK session per card (streaming-input mode, resumable by session id)   │
│ • mcpServers: per-card connector(s) + in-process `relay` MCP server        │
│ • canUseTool  → forwards permission requests to Swift UI                   │
│ • hooks (PostToolUse) → emits cross-card events → toasts                   │
│ • Code cards: cwd = repo or worktree, Claude Code preset system prompt     │
└──────────────┬─────────────────────────────────────────────────────────────┘
               ▼ spawns, one process per card
     your installed, unmodified `claude` binary
     (your claude.ai login from Keychain · ~/.claude config · plugins · skills ·
      MCP servers · claude.ai connectors such as Gmail, Calendar, Slack, Notion)
```

### Auth: use your existing Claude login (n = 1, personal use)
The Agent SDK is a library that runs the Claude Code binary, so if the sidecar spawns **your installed `claude`** you get your logged-in subscription and everything in `~/.claude` for free. Rules:
- **Use the unmodified `claude` binary** with your normal `/login`. Anthropic's terms explicitly allow signing in to the unmodified binary with your own subscription, and plan limits are described as covering "ordinary, individual usage of Claude Code and the Agent SDK".
- **Never read the OAuth token from Keychain and call the API yourself.** That's the third-party-harness pattern Anthropic blocked in 2026 (OpenCode, OpenClaw).
- **Don't set `ANTHROPIC_API_KEY`**, since it outranks the login, and **don't pass `--bare`**, which never reads OAuth.
- **Don't use `claude setup-token`.** Its token can't fetch claude.ai connectors. The normal `/login` gives you your claude.ai connectors (Gmail, Calendar, Slack, Notion), which are exactly the cards in the video, with zero connector code.
- If Relay is ever shipped to other people, revisit this. The SDK docs forbid third-party products from offering claude.ai login unless approved.

### Why this split
- **Swift owns pixels and feel.** Only native SwiftUI and AppKit gets you real vibrancy, Liquid Glass, ProMotion-smooth springs, the system text engine, VoiceOver and global hotkeys.
- **The Agent SDK owns the agent.** You get Claude Code's loop for free: tools, MCP, session resume, permissions, hooks, subagents, context compaction. No reimplementation. It's also the documented way to get `canUseTool` approvals and `interrupt()`. Raw `claude -p --input-format stream-json` works for streaming, but the approval and interrupt control channel is only documented through the SDK.
- **Code cards are the same thing pointed at a repo.** "Control Claude Code well" stops being a separate feature.
- **Sessions are shared with Claude Code.** A Relay card's session id resumes in a terminal (`claude --resume <id>`) or in the Claude desktop app, and the reverse. Add an "Open in Terminal" card action. An embedded SwiftTerm running interactive `claude --resume` is a good escape hatch for anything the card UI doesn't cover.
- The sidecar is a single compiled binary inside `Relay.app/Contents/Resources`. It finds `claude` on `PATH` (fallback `~/.local/bin/claude`).

### Optional companion: a Claude Code mod
Mods (Claude Code v2.1.287+) are TypeScript plugins that run inside the CLI and the desktop app's Code tab. Their UI is limited to Box/Text/Button/Input/Select/Markdown/Svg, with throttled redraws, so **the Relay interface itself can't be a mod**. A ~50-line `relay-bridge` mod is still useful for sessions you start *outside* Relay:
- `turn.start`/`tool.call` hooks → `$.http.fetch` to Relay's localhost port, so desktop and terminal sessions show up in Relay's grid with live status and needs-you states.
- Relay → session: a `$.clock.every` poll picks up queued prompts and calls `$.prompt.submit`. `$.session.send` messages between sessions.
- This is phase 2, not the MVP.

### Bridge protocol (keep it tiny)
Swift → sidecar: `open {cardId, kind, cwd?, mcp, model, resumeId?}` · `send {cardId, text, attachments}` · `interrupt {cardId}` · `permission {reqId, allow, remember}` · `setModel/permissionMode {cardId, …}`
Sidecar → Swift: `delta {cardId, text}` · `block {cardId, block}` · `tool {cardId, name, status, summary}` · `needsPermission {reqId, cardId, tool, input}` · `event {fromCard, toConnector, summary}` · `status {cardId, pill, state}` · `suggestions {cardId, [3]}` · `done {cardId, usage}`

### Blocks → Pages (the "pages" idea)
The in-process `relay` MCP server exposes one tool to Claude: **`show(block)`**, a JSON-schema'd union:
`calendarDay · emailDraft · message · fileChip · kanban · linkPreview · diff · terminal · todoList · table · image · approval`
Each block has a compact **inline view** and an expanded **PageView**. Pages use `matchedGeometryEffect` to zoom out of the bubble. Unknown or long content falls back to a Markdown page. Your system prompt: *"Prefer `show` over prose when the answer has structure."*

Suggestion chips come from a cheap follow-up call to Haiku 4.5 after each turn: last 6 messages → 3 imperative suggestions of ≤4 words each.

Status pills come from a `set_status(text, tone)` tool the agent may call ("3 threads waiting"). Otherwise the app derives them from state: running / needs you / idle.

### Cross-card events (the toasts)
A `PostToolUse` hook maps tool names to connectors (`mcp__gcal__*` → Calendar). When card A's agent writes to connector B:
1. it fires a toast (icon, name, summary), and
2. it appends a system line to card B's thread ("From Gmail: held Oct 21–23"), so B's agent sees it next turn.

That's what makes it feel like agents working *together*.

---

## 4. Controlling Claude Code well (Code cards)

| Need | How |
|---|---|
| See what it's doing without noise | Tool calls collapse into one live **activity line** ("Editing `Composer.swift` · 4 tools") that expands to a timeline. Prose stays as bubbles. |
| Approvals that don't block your flow | `canUseTool` → an inline **approval block** with the diff or command preview. Buttons: Allow once · Always for this repo · Deny with note. A pending approval sets the card pill to orange **"Needs you"** and fires a toast. `⌘↩` approves from anywhere. |
| Plan before acting | Per-card mode switch (Plan / Ask / Auto-edit / Auto). The plan renders as a `todoList` page that you edit, then hit Go. |
| Parallel agents without collisions | "New card from this repo" → automatic **git worktree** per card. The grid shows every agent's branch, state and diff size. |
| Live progress | The agent's TodoWrite list shows as a pinned mini-checklist under the header. |
| Review & ship | `diff` page (side-by-side, per-hunk accept/reject) → chips: *Run tests* · *Commit* · *Open PR*. |
| Steer mid-run | Typing while it runs queues the message (streaming input). `Esc` interrupts. |
| Resume anything | Import existing sessions from `~/.claude/projects/**.jsonl` as cards (read-only history, resume via session id). |
| Model / effort | Per-card picker in the header menu (Opus 5.5 for code, Sonnet 5.5 for connectors, Haiku 4.5 for chips and summaries). |
| Preview | Web projects: a `linkPreview` block for the dev server URL → expands to an in-app WKWebView page (the Aman moment). |

---

## 5. Visual & motion spec (Apple standards)

**Platform:** macOS 26+. Use the system **Liquid Glass** (`.glassEffect`, `GlassEffectContainer`) for the composer, toasts and pills. Cards use a dark material (`.ultraThinMaterial` plus a 70% `#0E1420` tint) so text stays readable over any wallpaper. Follow the system accent colour (default blue), Dark/Light, Increase Contrast and Reduce Transparency.

| Token | Value |
|---|---|
| Card radius / padding | 28pt / 16pt · bubble radius 18pt (continuous corners) |
| Type | SF Pro Text 15 body, 13 meta, 13 semibold header; SF Mono 12 for code |
| Bubble | user = `Color.accentColor`, white text · assistant = `white.opacity(0.08)` |
| Neighbour cards | `scrollTransition`: scale 0.94, opacity 0.55, blur 1.5, y +8 |
| Carousel | `ScrollView(.horizontal)` + `.scrollTargetBehavior(.viewAligned)` + `scrollPosition(id:)` |
| Card swipe spring | `.spring(duration: 0.45, bounce: 0)` (matches the video's no-overshoot settle) |
| Message appear | `.smooth(duration: 0.3)`: opacity 0→1, y 8→0, blur 4→0 |
| Mic ↔ send morph | `Image(systemName:)` + `.contentTransition(.symbolEffect(.replace))` |
| Typing dots | `PhaseAnimator`, 3 phases, 0.9s loop |
| Grid zoom | `matchedGeometryEffect` per card, `.snappy(duration: 0.4)`; render content from cached `ImageRenderer` snapshots during the transition, then swap to live views (this is the skeleton→content fade in the video) |
| Page expand | matched geometry from block → page, backdrop `blur(20)` + `black.opacity(0.35)` |
| Toast | slide in from top-right, `.spring(duration: 0.4, bounce: 0.15)`, stack max 3, auto-dismiss 4s, hover pauses |
| Reduce Motion | swap every move/scale for a 150ms cross-fade |

Frame rate rule: never block the main thread. Stream deltas coalesce at 30Hz into the store, `Text` uses `AttributedString` with incremental Markdown, and long threads use `LazyVStack` with stable ids.

---

## 6. Ship insanely fast

### Repo setup (day 0, ~1 hour)
- `project.yml` with **XcodeGen**, so Claude Code edits YAML instead of `.pbxproj`. One app target and one test target.
- `sidecar/` holds the TypeScript Agent SDK app, built with `bun build --compile` → a single binary copied in by a build phase.
- `Makefile`: `make run` (xcodegen + xcodebuild + open), `make shot` (`screencapture -l <windowid>` → `shots/latest.png` so Claude can check its own UI against `reference/`), `make release`.
- `CLAUDE.md`: points at this plan and `reference/`, tells Claude to run `make run && make shot` after UI changes and compare against the reference frame.
- **InjectionIII** for hot-reloading SwiftUI without relaunching, plus `#Preview`s with fixture threads for every block type.

### Release pipeline (so every merge can ship)
- Developer ID signing + `xcrun notarytool submit --wait` + `stapler` in `scripts/release.sh`.
- **Sparkle 2** auto-update with an EdDSA-signed appcast hosted on GitHub Releases (or Vercel).
- GitHub Actions on a `macos-15` runner: push a tag `v*` → build → sign → notarize → DMG → appcast. Merge to main ships to your own machine within minutes.
- Feature flags in a local `flags.json` let half-done work merge dark.

### Build order (vertical slices, each one shippable)
| Day | Slice | Done when |
|---|---|---|
| 0 ✅ | **Foundation** (done 2026-10-02, all checks pass; see `Relay/DAY0.md`): Swift ↔ sidecar bridge, 1 card streams a reply through your installed `claude` with no API key set. Confirm `system/init` lists your claude.ai connectors, then check `canUseTool`, `interrupt`, `resume`, streaming input. | text streams into a SwiftUI bubble, billed to your subscription |
| 1 | Panel + hotkey + carousel + shared composer + persistence | summon, swipe 3 scratch cards, quit, relaunch, history intact |
| 2 | **Code card**: repo picker, activity line, inline approvals, interrupt, todo checklist | run a real task in this repo from Relay end to end |
| 3 | Connectors via MCP (Gmail, Calendar, Slack, Notion) + connector picker + per-card status pill | "block my Monday" works from the Calendar card |
| 4 | Blocks: `calendarDay`, `emailDraft`, `diff`, `linkPreview`, `todoList` + page expand | the Aman-style zoom works |
| 5 | Grid overview + `⌘1–9` + needs-you states | 6 agents visible and controllable at once |
| 6 | Cross-card hook → toasts + system lines; suggestion chips (Haiku) | Gmail action toasts into Calendar |
| 7 | Voice (on-device speech), motion polish pass against `reference/`, Reduce Motion, VoiceOver labels | side-by-side with the video feels the same |
| 8 | Signing, notarization, Sparkle, CI | a tag produces an auto-updating DMG |
| 9+ | Worktrees per card, session import, kanban/table blocks, `@card` routing | — |

### Keep scope honest
- **v1 has no custom connector code.** Everything is an MCP server. If a good MCP exists, use it.
- **One window, one panel.** No settings window beyond a small SwiftUI `Settings` scene (hotkey, API key in Keychain, connectors).
- Read connector data only through the agent. No sync engines, no local mirrors.

---

## 7. Risks & open questions
1. **Auth.** Solved for personal use. The sidecar spawns your installed, logged-in `claude` (see §3). Policy here has changed several times in 2026, so re-check [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) if Anthropic announces changes. Subscription usage limits apply, and parallel Opus cards burn through them fast.
2. **Overlay vs window.** The video is a full-screen overlay. Ship overlay mode (hotkey) **and** a normal resizable window mode (for Stage Manager and external displays) from the same views.
3. **Cost and latency.** Sonnet 5.5 for connector cards and Opus 5.5 only for Code cards. Prompt caching on system prompt + tool defs. Haiku 4.5 for chips and summaries.
4. **Destructive connector actions** (send email, decline invite). Default those tools to `ask`, shown as the approval block. The "Drafted and sent" flow in the video becomes a one-tap approve.
5. **Sidecar crash.** Supervise it in Swift with restart + `resume` by session id, so a crash never costs a thread.
