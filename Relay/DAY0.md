# Day 0 results

Proves the Relay stack end to end on your Claude login: SwiftUI → JSON lines → Agent SDK sidecar → your installed `claude`.

## Run it

```bash
# 1. Headless CLI on your login (look for apiKeySource "none")
claude -p "Reply with exactly: relay ok" --output-format stream-json --verbose --model haiku < /dev/null | head -1

# 2. Sidecar checks (login, connectors, streaming, approvals, interrupt, resume)
cd Relay/sidecar && bun install && bun run test.ts

# 3. Native card window (type a message; Esc or the stop button interrupts; ⌘↩ approves)
cd Relay && swift run
```

Never export `ANTHROPIC_API_KEY` in the shell that launches these, because it outranks the claude.ai login.

## Results (2026-10-02, Claude Code 2.1.285, Agent SDK 0.3.288)

| Check | Result |
|---|---|
| Runs on claude.ai login, no API key (`apiKeySource: none`) | PASS |
| claude.ai connectors visible (Gmail, Calendar, Slack, Notion, Drive) | PASS |
| Token streaming into SwiftUI bubble (45 deltas) | PASS |
| `canUseTool` approval round-trip → tool runs | PASS |
| Interrupt stops a turn (8–120 ms) | PASS |
| Card keeps working after interrupt | PASS |
| `resume` restores history in a fresh process | PASS |

## Findings that change the build
- **Pass `pathToClaudeCodeExecutable` explicitly.** Without it the SDK runs its own bundled `claude`, not your installed one.
- **Interrupt keeps the session alive.** It ends the turn with `subtype: "error_during_execution"`. Show that as "Stopped" in the UI, not as an error. The sidecar also auto-resumes if a query ever ends after an interrupt.
- **Closing the input right after an interrupt makes the SDK throw.** The sidecar ignores errors while a card is closing.
- **`system/init` arrives once per turn**, not once per session. Dedupe it in the app.
- **`total_cost_usd` is an estimate of the equivalent API price.** On a subscription it isn't billed, so show it as usage, not dollars.
- Connectors can report `pending` at first and connect a few seconds later. Show a connecting state on the connector card.
- Swift: `.macOS(.v26)` needs `swift-tools-version: 6.2`. Keep SwiftUI bodies small, because large ones crash the type checker.
