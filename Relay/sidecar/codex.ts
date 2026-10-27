// Codex cards: the user's own Codex, signed in with their ChatGPT account, through `codex app-server`
// (JSON-RPC 2.0 over stdio). One app-server serves every Codex card, one thread per card. Its events are
// translated into the same JSON lines a Claude card sends, so the app treats both alike.
// Image generation and Computer Use come with Codex itself: a generated image becomes an image block, and
// Computer Use's "Allow … to use <app>?" question becomes an ordinary approval.
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

type Emit = (o: Record<string, unknown>) => void;

// The CLI inside ChatGPT.app first: it is signed for Computer Use (a Homebrew or npm codex gets
// "Sender process is not authenticated"), and it keeps up with the app's default model (the standalone
// 0.147 in ~/.local/bin rejects gpt-6.1-sol).
const CANDIDATES = [
  process.env.RELAY_CODEX_PATH,
  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
  "/Applications/Codex.app/Contents/Resources/codex",
];
function codexBinary() {
  const found = CANDIDATES.find((p) => p && existsSync(p));
  if (found) return found;
  try { return execSync("command -v codex", { shell: "/bin/zsh" }).toString().trim(); } catch { return ""; }
}

const IMAGES = process.env.HOME + "/Library/Application Support/Relay/images";

export const CODEX_PROMPT = `You can generate and edit images with your image generation tool, and operate the user's Mac apps \
with Computer Use. Relay shows every image you generate in the card itself, so don't copy or save it anywhere unless the user asks. \
Ask any question in your reply text; Relay can't show request_user_input. Ask before sending, posting, buying or deleting anything.`;

type OpenArgs = { cardId: string; cwd: string; resume?: string; fork?: boolean; system?: string };
type Card = {
  args: OpenArgs; threadId?: string; turnId?: string; closing: boolean;
  /** Resolves once the thread exists; sends wait on it. */
  ready: Promise<boolean>;
  /** Items in flight, for toolDone; agent messages that streamed deltas (the rest arrive whole). */
  items: Map<string, { name: string; input: Record<string, unknown> }>;
  streamed: Set<string>;
};
type Ask = { cardId: string; reply: (decision: string) => void };

export class Codex {
  private proc?: ChildProcess;
  private starting?: Promise<boolean>;
  private seq = 0;
  private calls = new Map<number, { resolve: (r: any) => void; reject: (e: Error) => void }>();
  private cards = new Map<string, Card>();
  private threads = new Map<string, string>(); // threadId → cardId
  private asks = new Map<string, Ask>();
  private askSeq = 0;
  private idle?: ReturnType<typeof setTimeout>;

  constructor(private emit: Emit) {}

  has(cardId: string) { return this.cards.has(cardId); }

  // MARK: The app-server process

  private server(): Promise<boolean> {
    if (this.proc && !this.starting) return Promise.resolve(true);
    if (this.starting) return this.starting;
    const bin = codexBinary();
    if (!bin) return Promise.resolve(false);
    // Codex signs in with ChatGPT (~/.codex/auth.json); an API key in the environment must not outrank it.
    const env = { ...process.env };
    delete env.OPENAI_API_KEY;
    const proc = spawn(bin, ["app-server"], { stdio: ["pipe", "pipe", "pipe"], env });
    this.proc = proc;
    proc.stderr!.on("data", (d) => { const line = String(d).trim(); if (/\b(ERROR|error:)/.test(line)) console.error("sidecar: codex: " + line.slice(0, 400)); });
    proc.stdin!.on("error", () => {});
    createInterface({ input: proc.stdout! }).on("line", (line) => this.receive(line));
    proc.on("exit", (code) => this.exited(proc, code));
    this.starting = (async () => {
      try {
        await this.call("initialize", { clientInfo: { name: "relay", title: "Relay", version: "1.0" }, capabilities: null });
        this.write({ method: "initialized" });
        return true;
      } catch (err) {
        console.error("sidecar: codex: initialize failed: " + String(err));
        proc.kill();
        return false;
      } finally {
        this.starting = undefined;
      }
    })();
    return this.starting;
  }

  private exited(proc: ChildProcess, code: number | null) {
    if (this.proc !== proc) return;
    this.proc = undefined;
    for (const c of this.calls.values()) c.reject(new Error("codex app-server exited"));
    this.calls.clear();
    this.asks.clear();
    // Every open card loses its thread; the app reopens it (resuming the thread) on its next message.
    for (const [cardId, card] of this.cards) {
      if (!card.closing && card.turnId) this.emit({ ev: "error", cardId, message: `Codex stopped (exit ${code ?? "signal"})` });
      this.emit({ ev: "closed", cardId });
    }
    this.cards.clear();
    this.threads.clear();
  }

  stop() { this.proc?.kill(); }

  private write(o: Record<string, unknown>) {
    try { this.proc?.stdin?.write(JSON.stringify(o) + "\n"); } catch {}
  }

  private call(method: string, params: unknown): Promise<any> {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.calls.set(id, { resolve, reject });
      this.write({ id, method, params });
    });
  }

  private receive(line: string) {
    let m: any;
    try { m = JSON.parse(line); } catch { return; }
    if (m.id != null && !m.method) {
      const c = this.calls.get(m.id);
      this.calls.delete(m.id);
      if (m.error) c?.reject(new Error(m.error.message ?? JSON.stringify(m.error)));
      else c?.resolve(m.result);
    } else if (m.id != null) {
      this.request(m.id, m.method, m.params ?? {});
    } else if (m.method) {
      this.notify(m.method, m.params ?? {});
    }
  }

  // MARK: Ops from the app

  open(args: OpenArgs) {
    if (this.cards.has(args.cardId)) return;
    clearTimeout(this.idle);
    const card: Card = { args, closing: false, ready: Promise.resolve(false), items: new Map(), streamed: new Set() };
    this.cards.set(args.cardId, card);
    card.ready = this.start(card);
  }

  private async start(card: Card): Promise<boolean> {
    const { cardId, cwd, resume, fork, system } = card.args;
    if (!(await this.server())) {
      this.cards.delete(cardId);
      this.emit({ ev: "error", cardId, message: "Couldn't start Codex. Is the ChatGPT app (with Codex) installed and signed in?" });
      this.emit({ ev: "closed", cardId });
      return false;
    }
    // workspace-write: Codex edits its folder freely and asks for anything beyond it, network included.
    const settings = { cwd, approvalPolicy: "on-request", sandbox: "workspace-write", developerInstructions: [system, CODEX_PROMPT].filter(Boolean).join("\n\n") };
    let res: any;
    try {
      if (resume) res = await this.call(fork ? "thread/fork" : "thread/resume", { threadId: resume, ...settings, excludeTurns: true });
    } catch (err) {
      console.error(`sidecar: codex: couldn't resume ${resume} (${String(err)}); starting a new thread`);
    }
    try {
      res ??= await this.call("thread/start", { ...settings, threadSource: "user" });
    } catch (err) {
      this.cards.delete(cardId);
      this.emit({ ev: "error", cardId, message: "Codex: " + String(err) });
      this.emit({ ev: "closed", cardId });
      return false;
    }
    if (card.closing) { void this.call("thread/unsubscribe", { threadId: res.thread.id }).catch(() => {}); return false; }
    card.threadId = res.thread.id;
    this.threads.set(res.thread.id, cardId);
    this.emit({ ev: "init", cardId, sessionId: res.thread.id, model: res.model, engine: "codex" });
    return true;
  }

  async send(cardId: string, text: string, images: string[] = []) {
    const card = this.cards.get(cardId);
    if (!card) return this.emit({ ev: "error", cardId, message: "not open" });
    if (!(await card.ready) || !card.threadId) return;
    const input = [{ type: "text", text, text_elements: [] }, ...images.map((path) => ({ type: "localImage", path }))];
    try {
      // A message sent mid-turn steers the turn already running instead of waiting behind it.
      if (card.turnId) await this.call("turn/steer", { threadId: card.threadId, expectedTurnId: card.turnId, input });
      else {
        const res = await this.call("turn/start", { threadId: card.threadId, input });
        card.turnId ??= res?.turn?.id;
      }
    } catch (err) {
      this.emit({ ev: "error", cardId, message: "Codex: " + String(err) });
    }
  }

  async interrupt(cardId: string) {
    const card = this.cards.get(cardId);
    if (!card?.threadId || !card.turnId) return;
    await this.call("turn/interrupt", { threadId: card.threadId, turnId: card.turnId }).catch(() => {});
  }

  close(cardId: string) {
    const card = this.cards.get(cardId);
    if (!card) return;
    card.closing = true;
    for (const [reqId, ask] of this.asks) if (ask.cardId === cardId) { this.asks.delete(reqId); ask.reply("deny"); }
    if (card.threadId) {
      if (card.turnId) void this.call("turn/interrupt", { threadId: card.threadId, turnId: card.turnId }).catch(() => {});
      void this.call("thread/unsubscribe", { threadId: card.threadId }).catch(() => {});
      this.threads.delete(card.threadId);
    }
    this.cards.delete(cardId);
    this.emit({ ev: "closed", cardId });
    // With no Codex cards left, the app-server goes too (it holds Codex's MCP servers and plugins).
    if (this.cards.size === 0) {
      clearTimeout(this.idle);
      this.idle = setTimeout(() => { if (this.cards.size === 0) this.stop(); }, 60_000);
    }
  }

  /** The user's answer to an approval; false when the request isn't Codex's. */
  answer(reqId: string, decision: string) {
    const ask = this.asks.get(reqId);
    if (!ask) return false;
    this.asks.delete(reqId);
    ask.reply(decision);
    return true;
  }

  // MARK: Codex → app

  private cardFor(params: any) {
    const cardId = this.threads.get(params.threadId);
    return cardId ? { cardId, card: this.cards.get(cardId)! } : undefined;
  }

  private notify(method: string, p: any) {
    const found = this.cardFor(p);
    if (!found) return;
    const { cardId, card } = found;
    switch (method) {
      case "turn/started":
        card.turnId = p.turn?.id;
        break;
      case "item/started": {
        const item = p.item ?? {};
        if (item.type === "agentMessage") { this.emit({ ev: "textStart", cardId }); break; }
        const tool = describe(item);
        if (!tool) break;
        card.items.set(item.id, tool);
        this.emit({ ev: "tool", cardId, name: tool.name, input: tool.input });
        break;
      }
      case "item/agentMessage/delta":
        card.streamed.add(p.itemId);
        if (p.delta) this.emit({ ev: "delta", cardId, text: p.delta });
        break;
      case "item/completed":
        this.completed(cardId, card, p.item ?? {});
        break;
      case "turn/completed": {
        card.turnId = undefined;
        card.items.clear();
        card.streamed.clear();
        const turn = p.turn ?? {};
        if (turn.status === "failed") {
          this.emit({ ev: "error", cardId, message: "Codex: " + (turn.error?.message ?? "the turn failed") });
          break;
        }
        this.emit({
          ev: "done", cardId, sessionId: card.threadId, durationMs: turn.durationMs,
          subtype: turn.status === "interrupted" ? "error_during_execution" : "success",
        });
        break;
      }
    }
  }

  private completed(cardId: string, card: Card, item: any) {
    if (item.type === "agentMessage") {
      // A message that arrived whole (no deltas) still needs its text in the thread.
      if (!card.streamed.has(item.id) && item.text) this.emit({ ev: "delta", cardId, text: item.text });
      return;
    }
    const tool = card.items.get(item.id) ?? describe(item);
    card.items.delete(item.id);
    if (item.type === "imageGeneration") {
      const path = item.status === "completed" ? saveImage(item) : undefined;
      if (path) this.emit({ ev: "block", cardId, block: { type: "image", title: caption(item.revisedPrompt), detail: item.revisedPrompt ?? undefined, location: path } });
      else this.emit({ ev: "toolDone", cardId, name: "Generate image", input: {}, isError: true, failed: true, error: item.failure?.message ?? "Image generation failed" });
      return;
    }
    if (!tool) return;
    const failed = item.status === "failed" || item.status === "declined" || (item.type === "commandExecution" && item.exitCode != null && item.exitCode !== 0);
    this.emit({ ev: "toolDone", cardId, name: tool.name, input: tool.input, isError: failed });
  }

  private request(id: number, method: string, p: any) {
    const respond = (result: unknown) => this.write({ id, result });
    const found = this.cardFor(p);
    if (!found || found.card.closing) {
      // No card to ask (it closed): decline rather than leave Codex waiting.
      if (method === "mcpServer/elicitation/request") return respond({ action: "decline", content: null, _meta: null });
      if (method.endsWith("requestApproval") || method === "applyPatchApproval" || method === "execCommandApproval") return respond({ decision: "decline" });
      return this.write({ id, error: { code: -32601, message: "No Relay card for this thread" } });
    }
    const { cardId } = found;
    const ask = (tool: string, input: Record<string, unknown>, canAlways: boolean, reply: (decision: string) => void) => {
      const reqId = `x${++this.askSeq}`;
      this.asks.set(reqId, { cardId, reply });
      this.emit({ ev: "needsPermission", cardId, reqId, tool, input, canAlways });
    };
    const decision = (d: string) => (d === "deny" ? "decline" : d === "always" ? "acceptForSession" : "accept");
    switch (method) {
      case "item/commandExecution/requestApproval":
        return ask("Bash", { command: shell(p.command ?? ""), cwd: p.cwd, summary: p.reason ?? undefined }, true,
          (d) => respond({ decision: decision(d) }));
      case "item/fileChange/requestApproval":
        return ask("Edit files", { file_path: p.grantRoot ?? undefined, summary: p.reason ?? "Change files" }, true,
          (d) => respond({ decision: decision(d) }));
      case "item/permissions/requestApproval":
        return ask("More access", { summary: p.reason ?? "Codex wants more access (network or files)" }, true, (d) => {
          const wanted = Object.fromEntries(Object.entries(p.permissions ?? {}).filter(([, v]) => v != null));
          respond(d === "deny" ? { permissions: {}, scope: "turn" } : { permissions: wanted, scope: d === "always" ? "session" : "turn" });
        });
      case "mcpServer/elicitation/request": {
        // Computer Use asks once per app ("Allow Computer Use to use "Finder"?"); other MCP servers ask here too.
        const meta = p._meta ?? {};
        const name = meta.connector_name ?? p.serverName ?? "Codex";
        const persist: string[] = Array.isArray(meta.persist) ? meta.persist : [];
        if (p.mode === "url") {
          return ask(name, { summary: `${p.message ?? "Open a page"} ${p.url ?? ""}`.trim() }, false,
            (d) => respond({ action: d === "deny" ? "decline" : "accept", content: null, _meta: null }));
        }
        return ask(name, { summary: p.message ?? `Allow ${name}?` }, persist.length > 0, (d) =>
          respond({
            action: d === "deny" ? "decline" : "accept",
            content: d === "deny" ? null : {},
            _meta: d === "always" ? { persist: persist.includes("always") ? "always" : persist[0] } : null,
          }));
      }
      case "item/tool/requestUserInput":
        // Relay has no form for this; the developer instructions ask Codex to put questions in its reply.
        return respond({ answers: {} });
      case "applyPatchApproval": case "execCommandApproval":
        return ask("Codex", { summary: p.reason ?? method }, false, (d) => respond({ decision: d === "deny" ? "denied" : "approved" }));
      default:
        return this.write({ id, error: { code: -32601, message: `Relay doesn't handle ${method}` } });
    }
  }
}

/** A Codex item as a Relay tool event: names the app already knows where it can (Bash, WebSearch). */
function describe(item: any): { name: string; input: Record<string, unknown> } | undefined {
  switch (item.type) {
    case "commandExecution": return { name: "Bash", input: { command: shell(item.command ?? "") } };
    case "fileChange": {
      const paths = (item.changes ?? []).map((c: any) => c.path).filter(Boolean);
      return { name: "Edit files", input: { file_path: paths[0], files: paths } };
    }
    case "mcpToolCall":
      if (item.server === "cua_repl") return { name: "Computer Use", input: { summary: item.arguments?.title ?? "Using your Mac" } };
      return { name: `mcp__${item.server}__${item.tool}`, input: item.arguments ?? {} };
    case "webSearch": return { name: "WebSearch", input: { query: item.query ?? item.action?.query ?? "" } };
    case "imageGeneration": return { name: "Generate image", input: {} };
    case "imageView": return { name: "View image", input: { file_path: item.path } };
    case "collabAgentToolCall": return { name: "Agent", input: {} };
    default: return undefined;
  }
}

/** `/bin/zsh -lc 'ls -la'` → `ls -la`: the command the user would recognize. */
function shell(command: string) {
  const m = command.match(/^\/bin\/(?:ba|z)?sh -lc '([\s\S]*)'$/);
  return m ? m[1]!.replace(/'\\''/g, "'") : command;
}

/** The revised prompt, trimmed to a caption: "Create a small square image of a single flat green leaf icon centered…" → "Single flat green leaf icon". */
function caption(prompt?: string | null) {
  if (!prompt) return "Generated image";
  // The imagegen skill leads with labels like "Use case: logo-brand."; the subject comes after.
  const first = prompt.replace(/^(?:[A-Z][\w -]{0,24}:\s*[\w/-]+\.\s*)+/, "")
    .split(/[.:;]\s|\s(?:centered|on an?|against|with)\s/)[0]!
    .replace(/^(Generate|Create|Make|Draw|Render)\s+/i, "")
    .replace(/^(an?\s+)?((tiny|small|simple|square|minimal|large),?\s+)*(image|picture|illustration|photo)\s+of\s+/i, "")
    .replace(/^(an?|one|the)\s+/i, "");
  const text = first.charAt(0).toUpperCase() + first.slice(1);
  return text.length > 60 ? text.slice(0, 59).trimEnd() + "…" : text;
}

/** Codex returns the picture as base64 (and sometimes a saved path); Relay keeps its own copy for the thread. */
function saveImage(item: any): string | undefined {
  if (item.savedPath && existsSync(item.savedPath)) return item.savedPath;
  if (!item.result) return undefined;
  try {
    mkdirSync(IMAGES, { recursive: true });
    const path = `${IMAGES}/${String(item.id).replace(/[^A-Za-z0-9_-]/g, "")}.png`;
    writeFileSync(path, Buffer.from(item.result, "base64"));
    return path;
  } catch (err) {
    console.error("sidecar: codex: couldn't save image: " + String(err));
    return undefined;
  }
}
