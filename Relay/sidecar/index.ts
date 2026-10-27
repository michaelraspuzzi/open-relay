// relay-agent: JSON-lines bridge between Relay (Swift) and the Claude Agent SDK.
// stdin  ← {op: "open" | "send" | "interrupt" | "permission" | "close" | "suggest" | "mail" | "slack" | "channels" | "notion" | "servers" | "probe" | "substackAuth" | "substack", ...}
// stdout → {ev: "ready" | "init" | "delta" | "tool" | "stalled" | "needsPermission" | "done" | "error" | "closed" | "suggestions" | "mail" | "notion" | "substackAccount" | "substackSaved", ...}
// Codex cards open with engine "codex" and run through codex.ts; send/interrupt/permission/close and the events are the same.
import { query, tool, createSdkMcpServer, type Query, type SDKUserMessage, type PermissionResult, type PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { execSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import * as substack from "./substack.ts";
import { Codex } from "./codex.ts";

// Never let an API key outrank the claude.ai login.
delete process.env.ANTHROPIC_API_KEY;
delete process.env.ANTHROPIC_AUTH_TOKEN;
delete process.env.CLAUDECODE;

const CLAUDE = process.env.RELAY_CLAUDE_PATH ?? execSync("command -v claude", { shell: "/bin/zsh" }).toString().trim();

const WORKSPACE = process.env.HOME + "/Library/Application Support/Relay/workspace";

// Every live query (cards, suggestions, pinned calls, probes): each owns a `claude` process and its MCP servers.
const live = new Set<Query>();
function track(q: Query) { live.add(q); return q; }
function release(q: Query) { live.delete(q); try { q.close(); } catch {} }

// Relay is gone (stdin closed, SIGTERM, parent died, or stdout broke): end every claude process, then exit.
// close() alone gives claude a 2 s grace before SIGTERM, on a timer exit would cancel; so signal the children now.
let exiting = false;
function shutdown(why: string) {
  if (exiting) return;
  exiting = true;
  console.error(`sidecar: shutting down (${why}), ${live.size} claude session(s)`);
  for (const q of live) try { q.close(); } catch {}
  codex.stop();
  spawnSync("pkill", ["-TERM", "-P", String(process.pid)]);
  process.exit(0);
}

const emit = (o: Record<string, unknown>) => {
  if (exiting) return;
  // With Relay gone, a write fails; reporting that by writing again would loop forever.
  try { process.stdout.write(JSON.stringify(o) + "\n"); } catch { shutdown("stdout closed"); }
};
process.stdout.on("error", () => shutdown("stdout closed"));

// Codex cards run the user's Codex (ChatGPT sign-in) through its app-server instead of claude.
const codex = new Codex(emit);

type Image = { mediaType: "image/png" | "image/jpeg" | "image/gif" | "image/webp"; data: string };
const MEDIA: Record<string, Image["mediaType"]> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp" };
function loadImages(paths: unknown): Image[] {
  if (!Array.isArray(paths)) return [];
  return paths.flatMap((path) => {
    const type = MEDIA[String(path).split(".").pop()?.toLowerCase() ?? ""];
    try { return type ? [{ mediaType: type, data: readFileSync(String(path)).toString("base64") }] : []; } catch { return []; }
  });
}

// A pushable async iterable: the card's prompt stream (streaming-input mode).
class Inbox implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private wake?: () => void;
  private closed = false;
  /** images: pasted screenshots and dropped pictures, sent to Claude inline (no Read tool, no approval). */
  push(text: string, images: Image[] = []) {
    const content = images.length
      ? [...images.map((i) => ({ type: "image" as const, source: { type: "base64" as const, media_type: i.mediaType, data: i.data } })), { type: "text" as const, text }]
      : text;
    this.items.push({ type: "user", message: { role: "user", content: content as any }, parent_tool_use_id: null });
    this.wake?.();
  }
  close() { this.closed = true; this.wake?.(); }
  drain() { return this.items.splice(0); }
  seed(items: SDKUserMessage[]) { this.items.push(...items); }
  async *[Symbol.asyncIterator]() {
    while (true) {
      while (this.items.length) yield this.items.shift()!;
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

// kind: "discover" | "ideas" add that card's block tool. autoAllowReads lets those cards look around without
// an approval per search; permissionMode "acceptEdits" is for night-shift code cards working in their own worktree.
type OpenArgs = {
  cardId: string; cwd: string; model?: string; resume?: string; system?: string;
  /** Resume `resume` as a new branch: a Claude Code session picked up from the desktop app stays untouched there. */
  fork?: boolean;
  kind?: string; permissionMode?: "default" | "acceptEdits"; autoAllowReads?: boolean;
  /** MCP servers this card needs; every other known server is denied so its process never starts. */
  keep?: string[];
  /** The user's other connectors and their servers, e.g. {calendar: ["google-calendar"]}; a scoped card can
   *  bring them in with use_connectors instead of starting every server up front. */
  reach?: Record<string, string[]>;
  /** Skills the user turned off in Relay (e.g. email-voice): hidden from this card's claude. */
  skillsOff?: string[];
};

// Every MCP server on this Mac (from the app's cache or a probe). Each `claude` would otherwise start all of them;
// denying the ones a session doesn't need is the difference between ~1.4 GB and ~0.4 GB per card.
let knownServers: string[] = [];
// Tool names keep letters, digits, "-" and "_": gmail-mcp → mcp__gmail-mcp__, "claude.ai Notion" → mcp__claude_ai_Notion__.
const toolPrefix = (server: string) => "mcp__" + server.replace(/[^A-Za-z0-9_-]/g, "_") + "__";
function scoped(keep: string[] | undefined) {
  if (!keep || knownServers.length === 0) return undefined;
  const deny = knownServers.filter((name) => !keep.includes(name));
  return deny.length ? { deniedMcpServers: deny.map((serverName) => ({ serverName })) } : undefined;
}
// A skill turned off in Relay is hidden from the model and from /name for that card's session.
function withSkillsOff(settings: ReturnType<typeof scoped>, off: string[] | undefined) {
  if (!off?.length) return settings;
  return { ...settings, skillOverrides: Object.fromEntries(off.map((name) => [name, "off" as const])) };
}
// interrupted: Esc was pressed. The query normally survives that; if it ends anyway we resume it.
// widen: servers use_connectors asked for; when the turn ends the session restarts with them and carries on.
// running: the card's tool calls still waiting on a result, with when they started. stalled: the call the watchdog stopped.
type Running = { name: string; input: any; since: number };
type Card = { inbox: Inbox; q: Query; args: OpenArgs; interrupted: boolean; closing: boolean; sessionId?: string; widen?: { servers: string[]; names: string[] };
  running: Map<string, Running>; stalled?: { name: string; minutes: number } };
const cards = new Map<string, Card>();
type Pending = { cardId: string; resolve: (r: PermissionResult) => void; input: Record<string, unknown>; suggestions?: PermissionUpdate[] };
const pending = new Map<string, Pending>();
let reqSeq = 0;

// Rich blocks: tools Claude calls to render structured results as cards in the chat (no approval needed).
const BLOCK_TOOLS = ["show_calendar_day", "show_invite", "show_email", "show_slack_message", "show_file", "show_link", "show_checklist", "show_note", "show_connector_picks", "show_ideas",
  "show_meeting_brief", "show_notion_database", "show_followups", "show_linkedin_post", "show_web_results", "show_substack_draft"]
  .map((n) => `mcp__relay__${n}`);

const USE_CONNECTORS = "mcp__relay__use_connectors";
const REACH_PROMPT = `This card starts with only its own connector. When a request needs another of the user's connectors \
(their calendar, inbox, Slack, Notion or Drive), call relay use_connectors to bring it in rather than saying you can't see it.`;

// Notion through the `ntn` CLI. The Notion MCP server can hang on a call for hours (a card sat on
// API-retrieve-page-markdown from 18:08 to 00:30 on 2026-10-04) and returns pages with every image's signed S3 URL;
// `ntn pages get` returns the same page with its properties in about a second. Each Notion account's token comes from
// its MCP server's NOTION_TOKEN and reaches the card's Bash as $NTN_TOKEN_<ACCOUNT>, so commands never spell it out.
const NTN = (() => { try { return execSync("command -v ntn", { shell: "/bin/zsh" }).toString().trim(); } catch { return ""; } })();
const NTN_ACCOUNTS: Record<string, string> = (() => {
  if (!NTN) return {};
  try {
    const servers = JSON.parse(readFileSync(process.env.HOME + "/.claude.json", "utf8")).mcpServers ?? {};
    return Object.fromEntries(Object.entries<any>(servers).flatMap(([name, s]) =>
      /^notion-/.test(name) && s?.env?.NOTION_TOKEN ? [[name, s.env.NOTION_TOKEN as string]] : []));
  } catch { return {}; }
})();
const ntnVar = (server: string) => "NTN_TOKEN_" + server.replace(/^notion-/, "").toUpperCase().replace(/[^A-Z0-9]/g, "_");
const ntnServers = (keep?: string[]) => Object.keys(NTN_ACCOUNTS).filter((s) => !keep || keep.includes(s));
function ntnPrompt(keep?: string[]) {
  const servers = ntnServers(keep);
  if (!servers.length) return "";
  const accounts = servers.map((s) => `${s} → NOTION_API_TOKEN=$${ntnVar(s)} ntn …`).join("; ");
  return `For Notion, use the ntn CLI through Bash first; it is faster and more reliable than the Notion MCP tools. \
Prefix every command with the account's token variable (${accounts}) and run each as a single command, no pipes. \
Reading needs no approval: \
\`ntn pages get <page-id>\` (a page as Markdown with its properties), \
\`ntn api v1/search query=<text> page_size:=10 'sort[timestamp]=last_edited_time' 'sort[direction]=descending'\` (find pages; leave out query for the most recent), \
\`ntn datasources query <data-source-id> --limit 25 --json\` (rows), \`ntn api v1/data_sources/<id>\` (a schema), \`ntn api v1/blocks/<id>/children\`. \
Write with \`ntn pages create\`, \`ntn pages edit\` or \`ntn api\` (\`ntn pages create --help\` shows the flags); the user approves each write. \
Use the Notion MCP tools only for what ntn can't do, \
and show_notion_database still takes the MCP toolPrefix.`;
}
// A read-only ntn command: the token prefix, then pages get, datasources query/resolve, whoami, a search or data
// source query (POSTs that change nothing), or any other api call that is a plain GET (no body, no -X).
function isNtnRead(command: unknown) {
  if (!NTN || typeof command !== "string") return false;
  const rest = command.trim().replace(/^NOTION_API_TOKEN=\$NTN_TOKEN_[A-Z0-9_]+\s+/, "");
  if (/[;&|<>`$\n\\]/.test(rest)) return false;
  const words = rest.split(/\s+/);
  if (words[0] !== "ntn" && words[0] !== NTN) return false;
  const [cmd, sub] = words.slice(1);
  if (cmd === "whoami" || words.includes("--help")) return true;
  if (cmd === "pages") return sub === "get";
  if (cmd === "datasources") return sub === "query" || sub === "resolve";
  if (cmd !== "api") return false;
  if (/^\/?v1\/(search|data_sources\/[0-9a-f-]+\/query)$/.test(sub ?? "")) return true;
  return !words.slice(3).some((w) => /^(-X|--method|-d|--data|--file)/.test(w) || /:=/.test(w) || /^[^=]+=(?!=)/.test(w.replace(/^'|'$/g, "")));
}

// Tools that change nothing outside Relay and never need an approval: drawing in Excalidraw.
const HARMLESS = (name: string) => /^mcp__claude_ai_Excalidraw__(read_me|create_view)$/.test(name);

// Looking, not touching: what Discover and Ideas cards may do without asking.
const READ_TOOLS = ["WebSearch", "WebFetch", "Read", "Glob", "Grep", "LS", "ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool"];
const READ_VERBS = ["get", "list", "search", "read", "find", "query", "fetch", "retrieve", "view", "suggest", "describe"];
const isRead = (name: string) => {
  if (READ_TOOLS.includes(name)) return true;
  if (!name.startsWith("mcp__")) return false;
  const action = (name.split("__").pop() ?? "").replace(/^API-/, "").toLowerCase();
  return READ_VERBS.some((v) => action.startsWith(v));
};

// Relay is the draft editor: a draft lives as a card until the user presses Save draft or Send (pinnedCall below).
// Agents may never save one into Gmail, Slack or anywhere else themselves, even if a settings rule allows it.
const DRAFT_VERBS = ["draft_email", "create_draft", "gmail_create_draft", "slack_send_message_draft", "create_draft_reply"];
const isDraftSave = (name: string) => {
  // Relay's own tools (the Substack card's draft reads) aren't another app's draft folder.
  if (!name.startsWith("mcp__") || name.startsWith("mcp__relay__") || isRead(name)) return false;
  return /draft/i.test(name.split("__").pop() ?? "");
};
const DRAFT_DENIED = "Drafts are shown in Relay, not saved. Show it with show_email or show_slack_message (status \"draft\"); the user saves or sends it from the card.";

export const BLOCKS_PROMPT = `When a result has structure, render it with a relay show_* tool instead of writing it out: \
show_calendar_day for a day's events, show_email for an email you drafted, sent or found, show_file for a file, \
show_link for a web page or URL, show_checklist for a plan or list of steps, show_note when the user wants to write down or keep thoughts \
(a note they can edit in place in the thread; put their words in it as they gave them, or leave the body empty for them to write), and show_slack_message for a Slack \
message you drafted or sent: draft one by showing it with show_slack_message (status "draft"), not by calling a Slack draft \
tool. Draft an email the same way, with show_email (status "draft"), never with a Gmail draft tool. To set up a new meeting \
or invite, show it with show_invite (status "draft") instead of creating the event: the user edits the time, guests and \
notes in Relay and presses Create invite. Drafts are never saved to Gmail or Slack by you: the user edits them in Relay and presses Save draft or Send. A draft that answers an email \
carries that email in replyTo and its threadId, so the user reads it beside the draft and the reply stays in the thread. Then keep your text reply to one short \
sentence that adds what the block doesn't say. Never repeat the block's contents in prose. \
Before you draft an email or message, load the user's writing-voice skill if one is listed (such as email-voice) and write in that voice.`;

// The Substack card: it reads your publications and drafts itself (no approval needed: nothing here writes), and shows
// drafts as cards. Only the card's Save button writes one (op "substack"); nothing can publish, schedule or delete.
const SUBSTACK_READS = ["substack_publications", "substack_drafts", "substack_read_draft"].map((n) => `mcp__relay__${n}`);
const SIGN_IN = { type: "link", title: "Sign in to Substack", url: "https://substack.com/sign-in", detail: "Opens in Relay, and you stay signed in" };

function substackTools(cardId: string, show: (block: Record<string, unknown>) => Promise<unknown>) {
  const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
  // Signed out (or the session ended): put a Sign in button in the thread and say so.
  const run = async (work: () => Promise<string>) => {
    try { return text(await work()); }
    catch (err) {
      if (!(err instanceof substack.SignedOut)) return { ...text(String((err as Error).message ?? err)), isError: true };
      emit({ ev: "block", cardId, block: SIGN_IN });
      return { ...text("The user isn't signed in to Substack. Relay showed them a Sign in button; ask them to sign in there, then send again. Don't retry until they do."), isError: true };
    }
  };
  const pubArg = z.string().optional().describe("The publication as the user said it: its name, subdomain, or a loose part of one. Leave out only when they have one publication");
  return [
    tool("substack_publications", "The Substack publications the user can write for, with their role on each.", {}, () => run(async () => {
      const me = await substack.account();
      return `Signed in as ${me.name} (@${me.handle}). Publications:\n` +
        me.pubs.map((p) => `- ${p.name}: subdomain ${p.subdomain}${p.customDomain ? `, ${p.customDomain}` : ""}, ${p.role}${p.primary ? ", primary" : ""}`).join("\n");
    }), { alwaysLoad: true }),
    tool("substack_drafts", "A publication's drafts, most recently edited first: id, title, subtitle, when edited, editor link.", {
      publication: pubArg, limit: z.number().int().min(1).max(50).optional(),
    }, (a) => run(async () => {
      const pub = await substack.pick(a.publication);
      const list = await substack.drafts(pub, a.limit ?? 15);
      return `${pub.name} (${pub.subdomain}): ${list.length ? "" : "no drafts."}\n` +
        list.map((d: any) => `- ${d.id}: ${d.title}${d.subtitle ? ` — ${d.subtitle}` : ""} (edited ${d.updated})`).join("\n");
    }), { alwaysLoad: true }),
    tool("substack_read_draft", "One draft in full: title, subtitle and body as Markdown. Lines like <!-- substack block 3: embed --> stand for images, embeds or buttons Relay can't show as text; keep them exactly where they are, and Relay puts the originals back when it saves.", {
      publication: pubArg, draftId: z.number().int(),
    }, (a) => run(async () => {
      const pub = await substack.pick(a.publication);
      const d = await substack.draft(pub, a.draftId);
      return JSON.stringify({ publication: pub.subdomain, ...d }, null, 1);
    }), { alwaysLoad: true }),
    tool("show_substack_draft", "Show a Substack post draft as an editable card. The user edits it there and presses Save to Substack (a new draft, or over draftId), then publishes from Substack. You never save or publish.", {
      publication: pubArg,
      draftId: z.number().int().optional().describe("The draft this revises, from substack_drafts; leave out for a new one"),
      synced: z.string().optional().describe("That draft's `updated` from substack_read_draft, so Relay won't save over edits made in Substack since"),
      title: z.string(),
      subtitle: z.string().optional(),
      body: z.string().describe("The post in Markdown: # headings, **bold**, *italic*, [links](url), lists, > quotes, --- breaks. Keep any <!-- substack block … --> lines"),
      notes: z.array(z.string()).optional().describe("For a revision: two to four short notes on what changed and why"),
    }, (a) => run(async () => {
      const pub = await substack.pick(a.publication);
      await show({ type: "substack", title: a.title, subtitle: a.subtitle ?? "", body: a.body, notes: a.notes,
        publication: pub.subdomain, channel: pub.name, status: "draft",
        ...(a.draftId && { postId: a.draftId, url: substack.editorUrl(pub, a.draftId), synced: a.synced }) });
      return "Shown to the user as a card.";
    }), { alwaysLoad: true }),
  ];
}

// Relay's web view signed in or out: tell the app who you are on Substack and which publications you run.
async function substackAuth(cookie: string) {
  if (!substack.setCookie(cookie ?? "")) return;
  if (!cookie) return emit({ ev: "substackAccount", signedIn: false });
  try {
    const me = await substack.account();
    emit({ ev: "substackAccount", signedIn: true, name: me.name, pubs: me.pubs.map((p) => p.name) });
  } catch (err) {
    emit({ ev: "substackAccount", signedIn: false, ...(!(err instanceof substack.SignedOut) && { error: String((err as Error).message ?? err) }) });
  }
}

// Save to Substack: the draft exactly as the user edited it in the card.
type SubstackCmd = { cardId: string; draftId: string; publication: string; postId?: number; title: string; subtitle?: string; body: string; synced?: string };
async function substackSave(cmd: SubstackCmd) {
  try {
    const saved = await substack.save(cmd);
    emit({ ev: "substackSaved", cardId: cmd.cardId, draftId: cmd.draftId, ok: true, ...saved });
  } catch (err) {
    emit({ ev: "substackSaved", cardId: cmd.cardId, draftId: cmd.draftId, ok: false,
      error: err instanceof substack.SignedOut ? "you're signed out of Substack; sign in from the Substack card" : String((err as Error).message ?? err) });
  }
}

function blockServer(cardId: string, kind?: string, reach?: Record<string, string[]>) {
  const show = (block: Record<string, unknown>) => {
    emit({ ev: "block", cardId, block });
    return Promise.resolve({ content: [{ type: "text" as const, text: "Shown to the user as a card." }] });
  };
  return createSdkMcpServer({
    name: "relay",
    tools: [
      tool("show_calendar_day", "Show a day's events as a calendar card.", {
        date: z.string().describe('Day label, e.g. "Wednesday, Oct 22"'),
        tag: z.string().optional().describe('Short status pill, e.g. "Focus held"'),
        events: z.array(z.object({ time: z.string(), title: z.string(), detail: z.string().optional() })),
      }, (a) => show({ type: "calendar", ...a }), { alwaysLoad: true }),
      tool("show_invite", "Show a calendar invite you drafted (or one already created) as an invite card. A draft is editable: the user changes the title, time, guests, place and notes, then creates it from the card, which sends the invites.", {
        status: z.enum(["draft", "created"]),
        title: z.string().describe("The event's title"),
        start: z.string().describe('Local start time, ISO 8601 without an offset, e.g. "2026-10-06T14:00:00"'),
        end: z.string().describe('Local end time, same format, e.g. "2026-10-06T14:30:00"'),
        guests: z.string().optional().describe("Guests' email addresses, comma-separated"),
        location: z.string().optional().describe("Room or address"),
        body: z.string().optional().describe("Description or agenda, plain text"),
        meet: z.boolean().optional().describe("Add a Google Meet link (true for remote meetings)"),
        url: z.string().optional().describe("For a created event: its calendar link"),
      }, ({ guests, ...a }) => show({ type: "invite", to: guests, ...a }), { alwaysLoad: true }),
      tool("show_email", "Show an email (draft, sent or received) as an email card.", {
        status: z.enum(["draft", "sent", "received"]),
        to: z.string().optional(), from: z.string().optional(),
        subject: z.string(), body: z.string(),
        replyTo: z.object({
          from: z.string(), date: z.string().optional(), body: z.string().describe("The email's full text, as read"),
        }).optional().describe("For a draft that answers an email: the email it answers, shown above the draft"),
        threadId: z.string().optional().describe("For a reply: the Thread ID read_email gave for the email it answers"),
        inReplyTo: z.string().optional().describe("For a reply: the answered email's Message-ID header (<...@...>), only if you have it"),
      }, (a) => show({ type: "email", ...a }), { alwaysLoad: true }),
      tool("show_slack_message", "Show a Slack message (draft or sent) as a message card. A draft is editable: the user saves it to their Slack drafts or sends it from the card.", {
        status: z.enum(["draft", "sent"]),
        channel: z.string().describe('Where it goes, as the user knows it: "#02-founders-log" or a person\'s name for a DM'),
        channelId: z.string().describe("The channel ID (C…) or, for a DM, the user ID (U…) from the Slack search tools"),
        body: z.string().describe("The message, in standard markdown; empty is fine when the user will write it"),
        threadTs: z.string().optional().describe("For a thread reply: the parent message's ts"),
        replyTo: z.object({
          from: z.string(), date: z.string().optional(), body: z.string().describe("The message's full text, as read"),
        }).optional().describe("For a reply: the message it answers, shown above the draft"),
        url: z.string().optional().describe("For a sent message: its permalink"),
      }, (a) => show({ type: "slack", ...a }), { alwaysLoad: true }),
      tool("show_file", "Show a file or attachment as a file chip.", {
        name: z.string(), kind: z.string().describe('e.g. "PDF", "Doc", "Sheet"'),
        detail: z.string().optional(), location: z.string().optional().describe("Local path or URL"),
      }, (a) => show({ type: "file", ...a }), { alwaysLoad: true }),
      tool("show_link", "Show a web page or URL as a link preview the user can open.", {
        title: z.string(), url: z.string(), detail: z.string().optional(),
      }, (a) => show({ type: "link", ...a }), { alwaysLoad: true }),
      tool("show_checklist", "Show a plan or list of steps as a checklist card.", {
        title: z.string(), items: z.array(z.object({ text: z.string(), done: z.boolean() })),
      }, (a) => show({ type: "checklist", ...a }), { alwaysLoad: true }),
      tool("show_note", "Show a note the user can write in and edit in place in the thread: for jotting down thoughts, ideas or anything to keep.", {
        title: z.string().describe('A short title, e.g. "Thoughts on the keynote"'),
        body: z.string().describe("The note's text, as plain text with line breaks; empty when the user will write it"),
      }, (a) => show({ type: "note", ...a }), { alwaysLoad: true }),
      ...(kind === "notion" || kind === "crm" ? [
        tool("show_notion_database", "Show a Notion database live in Relay, as a board (grouped by a status or select property) or a table. Relay loads the rows itself and keeps them in sync, and the user can move items between columns and tick checkboxes there. Use it whenever the user wants to see or work through a database, tracker, board or list in Notion. You only say which database.", {
          title: z.string().describe("The database's name"),
          dataSourceId: z.string().describe("The data source id (from API-post-search with filter object=data_source, or the database's data_sources)"),
          toolPrefix: z.string().describe('The prefix of the Notion tools you used, e.g. "mcp__notion-work__"; must be a server with API-query-data-source'),
          url: z.string().optional(),
          groupBy: z.string().optional().describe("A status or select property to show as board columns; omit for a table"),
          columns: z.array(z.string()).optional().describe("Up to 4 other property names worth showing"),
        }, (a) => show({ type: "notion", ...a }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "prep" ? [
        tool("show_meeting_brief", "Show a meeting prep brief as a card: who's coming and what you know about each, open threads, and what to cover.", {
          title: z.string().describe("The meeting's title"),
          when: z.string().describe('e.g. "Today · 2:30–3:00 PM"'),
          location: z.string().optional().describe("Room, address or video link"),
          url: z.string().optional().describe("The calendar event or video link"),
          summary: z.string().describe("One or two sentences: what this meeting is really about and what the user wants out of it"),
          attendees: z.array(z.object({
            name: z.string(), email: z.string().optional(),
            role: z.string().optional().describe('Title and company, e.g. "Programme lead, Config Berlin"'),
            about: z.string().describe("One or two sentences of what matters: history with the user, what they want, anything pending"),
            source: z.enum(["inbox", "calendar", "slack", "notion", "web", "none"]).describe("Where most of this came from"),
            link: z.string().optional().describe("A profile or page about them, for web results"),
          })),
          threads: z.array(z.object({
            subject: z.string(), from: z.string().optional(), date: z.string().optional(),
            gist: z.string().describe("One sentence, including anything still open"),
          })).optional().describe("Recent email or Slack threads that bear on this meeting"),
          points: z.array(z.string()).describe("3-6 things to raise, ask or decide, most important first"),
          links: z.array(z.object({ title: z.string(), url: z.string() })).optional().describe("Docs, decks or pages to have open"),
        }, (a) => show({ type: "brief", ...a }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "followups" ? [
        tool("show_followups", "Show what the user owes people and is waiting on as a card: each row has a button that hands its prompt back to you to draft, and a tick to mark it done.", {
          title: z.string().describe('e.g. "6 follow-ups this week"'),
          followups: z.array(z.object({
            who: z.string().describe("The person, as the user knows them"),
            about: z.string().describe("One short line: what's owed or pending"),
            kind: z.enum(["reply", "promise", "waiting"]),
            source: z.enum(["gmail", "slack"]),
            days: z.number().int().describe("Days since the message that started the wait"),
            link: z.string().optional().describe("The Gmail thread URL or Slack permalink"),
            prompt: z.string().describe("A complete instruction to draft the reply, the delivery or the nudge: who, the thread id or channel and ts, what was asked or promised. Never to send."),
          })).max(20),
        }, (a) => show({ type: "followups", ...a }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "linkedin" ? [
        tool("show_linkedin_post", "Show a LinkedIn post as an editable card with Get feedback and Post on LinkedIn buttons. The user posts it; you never do.", {
          title: z.string().describe("A short working title"),
          body: z.string().describe("The post exactly as it would appear on LinkedIn: plain text, blank lines between paragraphs, no markdown"),
          pillar: z.enum(["people", "projects", "partners"]).optional(),
          status: z.enum(["draft", "reviewed"]),
          scores: z.array(z.object({ name: z.enum(["Hook", "Voice", "Specifics", "Structure", "Close"]), score: z.number().int().min(1).max(5) })).optional().describe("For feedback: one per criterion"),
          notes: z.array(z.string()).optional().describe("For feedback: two to four short notes on what you changed and why"),
        }, (a) => show({ type: "post", ...a }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "web" ? [
        tool("show_web_results", "Show what you found on the web as a card: the answer, then the sources you used, each opening in Relay.", {
          query: z.string().describe("What the user asked, as a short title"),
          answer: z.string().describe("The answer in two to five plain sentences; no markdown, no links inline"),
          sources: z.array(z.object({
            title: z.string().describe("The page's title"),
            url: z.string(),
            note: z.string().optional().describe("One short line on what this source adds, with its date if it matters"),
          })).min(1).max(6).describe("Most useful first"),
        }, ({ query, answer, sources }) => show({ type: "search", title: query, summary: answer, links: sources }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "substack" ? substackTools(cardId, show) : []),
      ...(reach && Object.keys(reach).length ? [
        tool("use_connectors", "Bring the user's other connectors into this card when a request needs them, e.g. their calendar to diagram their week. After calling it, end your turn without replying: Relay reconnects you with those tools and you carry on.", {
          connectors: z.array(z.enum(Object.keys(reach) as [string, ...string[]])).min(1),
        }, (a) => {
          const card = cards.get(cardId);
          const servers = [...new Set(a.connectors.flatMap((c) => reach[c] ?? []))].filter((s) => !card?.args.keep?.includes(s));
          if (!card || servers.length === 0) return Promise.resolve({ content: [{ type: "text" as const, text: "Those connectors are already here; go ahead." }] });
          card.widen = { servers, names: a.connectors };
          emit({ ev: "reach", cardId, servers });
          return Promise.resolve({ content: [{ type: "text" as const, text: `Connecting ${a.connectors.join(", ")}. End your turn now without replying.` }] });
        }, { alwaysLoad: true }),
      ] : []),
      ...(kind === "discover" ? [
        tool("show_connector_picks", "Show your connector recommendations as a card with Set up and Learn more buttons.", {
          title: z.string().describe('e.g. "3 connectors to try"'),
          picks: z.array(z.object({
            name: z.string().describe('Product name, e.g. "Linear"'),
            category: z.string().describe('2-3 words, e.g. "Issue tracking"'),
            why: z.string().describe("One sentence on why it fits this user, citing what you noticed"),
            url: z.string().optional().describe("Where to read about or install it"),
            setup: z.string().optional().describe('How to add it: "claude.ai connector directory" or the exact `claude mcp add …` command'),
          })).min(1).max(5),
        }, (a) => show({ type: "connectors", ...a }), { alwaysLoad: true }),
      ] : []),
      ...(kind === "ideas" ? [
        tool("show_ideas", "Show your suggestions as a card; each idea gets a button that runs it in the right Relay card.", {
          title: z.string().describe('e.g. "4 things you could do now"'),
          night: z.boolean().describe("True for night-shift suggestions (long, unattended tasks)"),
          ideas: z.array(z.object({
            title: z.string().describe("Imperative, at most 6 words"),
            why: z.string().describe("One sentence citing the evidence: the email, meeting, repo or history item"),
            connector: z.enum(["gmail", "calendar", "slack", "notion", "crm", "drive", "code"]).describe("Which Relay card runs it"),
            prompt: z.string().describe("The complete instruction that card's agent will be given. It starts with no other context, so carry everything: what the user asked for (keep their own words and every detail they gave), the facts, names, links and dates you found, and what not to do. Never shorten or generalize what the user asked for."),
            minutes: z.number().describe("Estimated agent time in minutes (60-300 for night shift)"),
            folder: z.string().optional().describe("Absolute repo path, for code ideas"),
            priority: z.enum(["high", "normal"]).optional().describe("high for the one or two that matter most right now"),
          })).min(1).max(5),
        }, (a) => show({ type: "ideas", ...a }), { alwaysLoad: true }),
      ] : []),
    ],
  });
}

// Tool inputs can be large (Write content); keep what the app needs.
const clip = (input: unknown) => {
  const text = JSON.stringify(input ?? {});
  return text.length > 40_000 ? { truncated: true } : input;
};

async function open(args: OpenArgs, carry: SDKUserMessage[] = []) {
  const { cardId } = args;
  const inbox = new Inbox();
  inbox.seed(carry);
  const q = track(query({
    prompt: inbox,
    options: {
      pathToClaudeCodeExecutable: CLAUDE,
      cwd: args.cwd,
      model: args.model,
      resume: args.resume,
      forkSession: args.fork,
      systemPrompt: { type: "preset", preset: "claude_code", append: (args.system ?? "") + "\n\n" + BLOCKS_PROMPT + (args.reach ? "\n\n" + REACH_PROMPT : "") + (ntnPrompt(args.keep) && "\n\n" + ntnPrompt(args.keep)) },
      // A stuck MCP call fails after 90 s instead of leaving the card spinning; the Notion accounts' tokens are there for ntn.
      env: { ...process.env, MCP_TOOL_TIMEOUT: "90000", ...Object.fromEntries(ntnServers(args.keep).map((s) => [ntnVar(s), NTN_ACCOUNTS[s]])) },
      mcpServers: { relay: blockServer(cardId, args.kind, args.reach) },
      settings: withSkillsOff(scoped(args.keep), args.skillsOff),
      // Claude Code cards can drive the user's Chrome (Claude in Chrome) for web tasks: sites and dashboards.
      extraArgs: args.kind === "code" ? { chrome: null } : undefined,
      permissionMode: args.permissionMode ?? "default",
      // Beats any "always allow" rule in settings, which would otherwise skip canUseTool.
      disallowedTools: knownServers.flatMap((s) => DRAFT_VERBS.map((v) => toolPrefix(s) + v)),
      includePartialMessages: true,
      canUseTool: (toolName, input, { signal, suggestions }) =>
        isDraftSave(toolName) ? Promise.resolve({ behavior: "deny", message: DRAFT_DENIED }) :
        BLOCK_TOOLS.includes(toolName) || toolName === USE_CONNECTORS || HARMLESS(toolName) || SUBSTACK_READS.includes(toolName) || (args.autoAllowReads && isRead(toolName)) ||
        (toolName === "Bash" && ntnServers(args.keep).length > 0 && isNtnRead(input.command)) ? Promise.resolve({ behavior: "allow", updatedInput: input }) :
        new Promise<PermissionResult>((resolve) => {
          const reqId = `r${++reqSeq}`;
          pending.set(reqId, { cardId, resolve, input, suggestions });
          signal.addEventListener("abort", () => {
            pending.delete(reqId);
            resolve({ behavior: "deny", message: "aborted" });
          });
          emit({ ev: "needsPermission", cardId, reqId, tool: toolName, input, canAlways: !!suggestions?.length });
        }),
    },
  }));
  const card: Card = { inbox, q, args, interrupted: false, closing: false, sessionId: args.resume, running: new Map() };
  const toolUses = card.running;
  cards.set(cardId, card);

  try {
    for await (const m of q) {
      switch (m.type) {
        case "system":
          if (m.subtype === "init") {
            card.sessionId = m.session_id;
            emit({ ev: "init", cardId, sessionId: m.session_id, model: m.model, apiKeySource: m.apiKeySource });
          }
          break;
        case "stream_event": {
          const e = m.event as any;
          if (e.type === "content_block_delta" && e.delta?.type === "text_delta") emit({ ev: "delta", cardId, text: e.delta.text });
          if (e.type === "content_block_start" && e.content_block?.type === "text") emit({ ev: "textStart", cardId });
          break;
        }
        case "assistant":
          if (m.parent_tool_use_id) break;
          // API failures (expired login, rate limit) arrive as one synthetic message that never streams, so the card
          // would show nothing at all (Gmail card, 2026-10-16): pass the text on, with the fix for a lapsed login.
          if ((m as any).error) {
            const said = (m.message.content as any[]).map((b) => b.text ?? "").join("").trim();
            const hint = (m as any).error === "authentication_failed"
              ? "\n\nYour Claude login has expired. Open Terminal, run `claude`, type `/login`, then send again." : "";
            emit({ ev: "textStart", cardId });
            emit({ ev: "delta", cardId, text: (said || String((m as any).error)) + hint });
            break;
          }
          for (const b of m.message.content as any[])
            if (b.type === "tool_use") {
              toolUses.set(b.id, { name: b.name, input: b.input, since: Date.now() });
              emit({ ev: "tool", cardId, name: b.name, input: clip(b.input) });
            }
          break;
        case "user": {
          // Tool results: report finished calls (cross-card notices, code diffs, whether a send really went out).
          const content = (m.message as any).content;
          if (!Array.isArray(content)) break;
          for (const b of content)
            if (b.type === "tool_result" && toolUses.has(b.tool_use_id)) {
              const use = toolUses.get(b.tool_use_id)!;
              toolUses.delete(b.tool_use_id);
              const text = Array.isArray(b.content) ? b.content.map((c: any) => c.text ?? "").join(" ") : String(b.content ?? "");
              const error = failure(use.name, text, !!b.is_error);
              emit({ ev: "toolDone", cardId, name: use.name, input: clip(use.input), isError: !!b.is_error, ...(error && { failed: true, error }) });
            }
          break;
        }
        case "result":
          // use_connectors asked for more servers: restart with them instead of ending the turn (see finally).
          if (card.widen) { card.inbox.close(); break; }
          // The watchdog stopped a hung call: this turn's end is that interrupt, so start the next one instead of finishing.
          if (card.stalled) { toolUses.clear(); card.inbox.push(carryOn(card.stalled)); card.stalled = undefined; break; }
          emit({
            ev: "done", cardId, subtype: m.subtype, sessionId: m.session_id,
            result: (m as any).result, costUsd: m.total_cost_usd, durationMs: m.duration_ms,
          });
          break;
      }
    }
  } catch (err) {
    if (!card.interrupted && !card.closing) emit({ ev: "error", cardId, message: String(err) });
  } finally {
    cards.delete(cardId);
    release(q);
    if (card.widen && !card.closing && card.sessionId) {
      const { servers, names } = card.widen;
      const carry = inbox.drain();
      const resumeNote: SDKUserMessage = { type: "user", parent_tool_use_id: null,
        message: { role: "user", content: `(Relay: ${names.join(", ")} connected. Carry on with my last request.)` } };
      void open({ ...args, keep: [...(args.keep ?? []), ...servers], resume: card.sessionId, fork: false }, [resumeNote, ...carry]);
    } else if (card.interrupted && !card.closing && card.sessionId) {
      const carry = inbox.drain();
      inbox.close();
      void open({ ...args, resume: card.sessionId, fork: false }, carry);
    } else {
      emit({ ev: "closed", cardId });
    }
  }
}

// Stall watchdog. A tool call can hang with no error at all: on 2026-10-05 a Notion card's WebSearch sat for
// 20 minutes while its twin, sent the same second, came back in 14 s. MCP calls already fail after 90 s
// (MCP_TOOL_TIMEOUT); built-in tools have no limit, so every call gets one here. A call past its limit is interrupted
// and the card is told to carry on without it; if the interrupt itself doesn't land, the session restarts (resumed).
const MIN = 60_000;
const STALL_TEST = Number(process.env.RELAY_STALL_MS) || 0; // test hook: one short limit for every call
function stallLimit(r: Running): number {
  if (STALL_TEST) return STALL_TEST;
  if (r.name === "Task" || r.name === "Agent") return 60 * MIN;
  if (r.name === "Bash") return r.input?.run_in_background ? 2 * MIN : (Number(r.input?.timeout) || 2 * MIN) + 3 * MIN;
  if (r.name === "WebSearch" || r.name === "WebFetch") return 3 * MIN;
  if (r.name.startsWith("mcp__claude-in-chrome__") || r.name.startsWith("mcp__Claude_Browser__")) return 5 * MIN;
  if (r.name.startsWith("mcp__")) return 4 * MIN;
  return 10 * MIN;
}
setInterval(() => {
  const now = Date.now();
  for (const [cardId, card] of cards) {
    if (card.closing || card.interrupted) continue;
    // Time spent waiting on the user's approval isn't a hang: restart those clocks.
    if ([...pending.values()].some((p) => p.cardId === cardId)) { for (const r of card.running.values()) r.since = now; continue; }
    if (card.stalled) continue;
    for (const r of card.running.values()) {
      if (now - r.since < stallLimit(r)) continue;
      const minutes = Math.max(1, Math.round((now - r.since) / MIN));
      card.stalled = { name: r.name, minutes };
      console.error(`sidecar: stall: card ${cardId} ${r.name} no result after ${minutes} min; interrupting`);
      emit({ ev: "stalled", cardId, name: r.name, minutes });
      void card.q.interrupt().catch(() => {});
      // The interrupt should end the turn within seconds; if it doesn't, restart the session.
      setTimeout(() => {
        if (cards.get(cardId) !== card || !card.stalled) return;
        console.error(`sidecar: stall: card ${cardId} interrupt didn't land; restarting the session`);
        card.inbox.push(carryOn(card.stalled));
        card.interrupted = true;
        release(card.q);
      }, 30_000);
      break;
    }
  }
}, 15_000).unref();
const carryOn = (s: { name: string; minutes: number }) =>
  `(Relay: your ${s.name} call hung for ${s.minutes} min with no result, so I stopped it. Carry on with my last request without it: ` +
  `try once more or another way, and if it's still stuck, skip that part and say so.)`;

// Three short follow-ups for a card's footer. One warm Haiku session answers every request (no tools, no MCP,
// not saved) instead of starting a `claude` process per reply; it sleeps after two idle minutes and is renewed
// every 25 requests so its context stays small.
class Suggester {
  private inbox?: Inbox;
  private q?: Query;
  private waiting: string[] = [];
  private uses = 0;
  private idle?: ReturnType<typeof setTimeout>;

  ask(cardId: string, connector: string, transcript: string) {
    if (!this.q || this.uses >= 25) this.start();
    this.uses++;
    this.waiting.push(cardId);
    this.inbox!.push(`Connector: ${connector}\n\nRecent conversation:\n${transcript || "(none yet)"}`);
    clearTimeout(this.idle);
    this.idle = setTimeout(() => this.stop(), 120_000);
  }

  private start() {
    this.stop();
    const inbox = new Inbox();
    const q = track(query({
      prompt: inbox,
      options: {
        pathToClaudeCodeExecutable: CLAUDE,
        model: "haiku",
        tools: [],
        settingSources: [],
        strictMcpConfig: true,
        mcpServers: {},
        settings: { disableClaudeAiConnectors: true },
        persistSession: false,
        systemPrompt:
          "You write the three quick-reply chips under a chat card in a Mac app. Every message is a separate request: " +
          "answer only for the conversation in that message. Each chip is something the user would plausibly ask next " +
          "for that connector: an imperative of 2-4 words, sentence case, no trailing punctuation, specific to the conversation when there is one.",
        outputFormat: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: { suggestions: { type: "array", items: { type: "string" }, minItems: 3, maxItems: 3 } },
            required: ["suggestions"],
          },
        },
      },
    }));
    this.inbox = inbox;
    this.q = q;
    this.uses = 0;
    void (async () => {
      try {
        for await (const m of q) {
          if (m.type !== "result") continue;
          const cardId = this.waiting.shift();
          const out = (m as any).structured_output?.suggestions;
          if (cardId && m.subtype === "success" && Array.isArray(out)) emit({ ev: "suggestions", cardId, items: out.slice(0, 3) });
        }
      } catch (err) {
        emit({ ev: "error", message: "suggest: " + String(err) });
      } finally {
        release(q);
        if (this.q === q) { this.q = undefined; this.inbox = undefined; this.waiting = []; }
      }
    })();
  }

  stop() {
    clearTimeout(this.idle);
    if (this.q) release(this.q);
    this.inbox?.close();
    this.inbox = undefined;
    this.q = undefined;
    this.waiting = [];
  }
}
const suggester = new Suggester();

// Claude Code writes a large tool result to a file and hands back a preview; read the whole thing back.
function spilled(text: string) {
  const path = text.startsWith("<persisted-output>") ? text.match(/saved to: (\S+)/)?.[1] : undefined;
  if (!path) return text;
  try {
    const raw = readFileSync(path, "utf8");
    const blocks = parse(raw);
    return Array.isArray(blocks) ? blocks.map((c: any) => c.text ?? "").join(" ") : raw;
  } catch { return text; }
}

// What each write tool says when it really happened. Without it, a reply that isn't flagged as an error still doesn't
// count as done: gmail-mcp and the Notion server both report failures as ordinary text. Slack has no entry (its success
// shape isn't pinned down, and a false "couldn't send" would invite a duplicate).
const PROOF: Record<string, RegExp> = {
  send_email: /sent successfully with ID/i,
  draft_email: /draft created successfully/i,
  "create-event": /"id"\s*:\s*"/,
  "API-patch-page": /"object"\s*:\s*"page"/,
};

/** Why a tool call failed, or undefined if it worked. Also catches failures sent as ordinary text: {"ok":false,…},
 *  gmail-mcp's "Error: …", the Notion server's {"status":400,"object":"error",…}. */
function failure(tool: string, text: string, isError: boolean): string | undefined {
  const proof = PROOF[tool.split("__").pop() ?? tool];
  const failed = isError || /"ok"\s*:\s*false|"error"\s*:\s*"|"object"\s*:\s*"error"|"status"\s*:\s*"error"|^\s*Error:/.test(text)
    || (proof && !proof.test(text));
  return failed ? text.slice(0, 300) || "it returned nothing" : undefined;
}

// Save or send a draft exactly as the user edited it. One narrow turn that may call only `verb` on that account's
// server, and its arguments are pinned to the user's text, so the model can't reword anything.
async function pinnedCall(prefix: string, verb: string, args: Record<string, unknown>, bigOutput = false): Promise<{ ok: boolean; error?: string; text?: string }> {
  const matches = (name: string) => name.startsWith(prefix) && name.endsWith("__" + verb);
  let toolId: string | undefined;
  let result: { ok: boolean; error?: string; text?: string } | undefined;
  let q: Query | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    q = track(query({
      prompt: `Call the ${verb} tool whose name starts with ${prefix} exactly once with these arguments, then reply "done".\n${JSON.stringify(args)}`,
      options: {
        pathToClaudeCodeExecutable: CLAUDE, cwd: WORKSPACE, model: "haiku", persistSession: false, maxTurns: 4,
        // Only the account that does this starts.
        settings: scoped(knownServers.filter((name) => toolPrefix(name) === prefix)),
        // Claude Code clips large MCP results to 25k tokens; a Notion query can be bigger.
        ...(bigOutput && { env: { ...process.env, MAX_MCP_OUTPUT_TOKENS: "150000" } }),
        canUseTool: (name) => Promise.resolve(matches(name)
          ? { behavior: "allow", updatedInput: args }
          : { behavior: "deny", message: `Only ${verb} is allowed here.` }),
      },
    }));
    // A hung MCP server must not keep this claude alive: give up after two minutes.
    const stuck = q;
    timer = setTimeout(() => { result ??= { ok: false, error: `${verb} timed out` }; release(stuck); }, 120_000);
    for await (const m of q) {
      if (m.type === "assistant")
        for (const b of m.message.content as any[]) if (b.type === "tool_use" && matches(b.name)) toolId = b.id;
      if (m.type === "user" && Array.isArray((m.message as any).content))
        for (const b of (m.message as any).content)
          if (b.type === "tool_result" && b.tool_use_id === toolId) {
            const text = spilled(Array.isArray(b.content) ? b.content.map((c: any) => c.text ?? "").join(" ") : String(b.content ?? ""));
            const error = failure(verb, text, !!b.is_error);
            result = error ? { ok: false, error } : { ok: true, text };
          }
      // The call happened: no need to wait for the model to read the result and say "done".
      if (result) break;
    }
  } catch (err) {
    result ??= { ok: false, error: String(err) };
  } finally {
    // Leaving the loop early must not leave this account's claude and MCP server running.
    clearTimeout(timer);
    if (q) release(q);
  }
  return result ?? { ok: false, error: `No ${verb} tool found for ${prefix.replace(/^mcp__|__$/g, "")}` };
}

// A Slack message as the user edited it: saved to their Slack drafts, or sent.
type SlackCmd = { cardId: string; draftId: string; action: "send" | "draft"; prefix: string; channelId: string; body: string; threadTs?: string };
async function slack(cmd: SlackCmd) {
  const verb = cmd.action === "send" ? "slack_send_message" : "slack_send_message_draft";
  const args = { channel_id: cmd.channelId, message: cmd.body, ...(cmd.threadTs && { thread_ts: cmd.threadTs }) };
  const { text, ...result } = await pinnedCall(cmd.prefix, verb, args);
  const url = text?.match(/https:\/\/[^\s"'\\]*slack\.com[^\s"'\\]*/)?.[0];
  emit({ ev: "mail", cardId: cmd.cardId, draftId: cmd.draftId, action: cmd.action, ...result, ...(url && { url }) });
}

// The Slack channels you're in, for a new Slack draft's "In" picker. Same narrow pinned turn, read-only.
async function channels(prefix: string) {
  const { ok, error, text } = await pinnedCall(prefix, "slack_list_user_channels", { limit: 200, exclude_archived: true });
  // Results come back as markdown ("### #name\n- **ID:** C…"), sometimes inside a JSON string with escaped newlines.
  const md = (text ?? "").replace(/\\n/g, "\n");
  const items = [...md.matchAll(/###\s*#?([^\n]+)\n-\s*\*\*ID:\*\*\s*([A-Z0-9]+)/g)].map((m) => ({ name: m[1]!.trim(), id: m[2]! }));
  emit({ ev: "channels", ok: ok && items.length > 0, items, ...(error && { error }) });
}

// An email as the user edited it: saved to Gmail drafts, or sent.
type MailCmd = {
  cardId: string; draftId: string; action: "send" | "draft"; prefix: string; to: string; subject: string; body: string;
  threadId?: string; inReplyTo?: string;
};
async function mail(cmd: MailCmd) {
  const verb = cmd.action === "send" ? "send_email" : "draft_email";
  // gmail-mcp takes bare addresses only: "Ana Example <ana@example.org>" fails its check, so send just the address.
  const to = [...new Set(cmd.to.match(/[^\s<>,;"()]+@[^\s<>,;"()]+\.[^\s<>,;"()]+/g) ?? [])];
  const args = {
    to, subject: cmd.subject, body: cmd.body,
    ...(cmd.threadId && { threadId: cmd.threadId }), ...(cmd.inReplyTo && { inReplyTo: cmd.inReplyTo }),
  };
  const { text: _, ...result } = await pinnedCall(cmd.prefix, verb, args);
  emit({ ev: "mail", cardId: cmd.cardId, draftId: cmd.draftId, action: cmd.action, ...result });
}

// A calendar invite as the user edited it, created on their primary calendar; guests get the invitations.
type InviteCmd = {
  cardId: string; draftId: string; prefix: string; title: string; start: string; end: string; timeZone: string;
  guests: string; location?: string; body?: string; meet?: boolean;
};
async function invite(cmd: InviteCmd) {
  const emails = [...new Set(cmd.guests.match(/[^\s<>,;"()]+@[^\s<>,;"()]+\.[^\s<>,;"()]+/g) ?? [])];
  const args = {
    calendarId: "primary", summary: cmd.title, start: cmd.start, end: cmd.end, timeZone: cmd.timeZone,
    sendUpdates: emails.length ? "all" : "none",
    ...(emails.length && { attendees: emails.map((email) => ({ email })) }),
    ...(cmd.location && { location: cmd.location }), ...(cmd.body && { description: cmd.body }),
    ...(cmd.meet && { conferenceData: { createRequest: { requestId: crypto.randomUUID(), conferenceSolutionKey: { type: "hangoutsMeet" } } } }),
  };
  const { text, ...result } = await pinnedCall(cmd.prefix, "create-event", args);
  const url = text?.match(/https:\/\/(?:www\.google\.com\/calendar|calendar\.google\.com)[^\s"'\\)]*/)?.[0];
  emit({ ev: "mail", cardId: cmd.cardId, draftId: cmd.draftId, action: "invite", ...result, ...(url && { url }) });
}

// Live Notion databases: load a data source's schema and rows, or change one property on one page, through the
// official Notion server's API-* tools. Rows are flattened to text so the app doesn't need Notion's object model.
type NotionCmd = { reqId: string; action: "query" | "update"; prefix: string; dataSourceId?: string; pageId?: string; properties?: Record<string, unknown> };
const plain = (rich: any) => Array.isArray(rich) ? rich.map((r: any) => r.plain_text ?? r.text?.content ?? "").join("") : "";
function propText(p: any): string {
  if (!p) return "";
  switch (p.type) {
    case "title": case "rich_text": return plain(p[p.type]);
    case "status": case "select": return p[p.type]?.name ?? "";
    case "multi_select": return (p.multi_select ?? []).map((o: any) => o.name).join(", ");
    case "checkbox": return p.checkbox ? "true" : "false";
    case "number": return p.number == null ? "" : String(p.number);
    case "date": return p.date ? p.date.start + (p.date.end ? " → " + p.date.end : "") : "";
    case "people": return (p.people ?? []).map((u: any) => u.name ?? "").filter(Boolean).join(", ");
    case "url": case "email": case "phone_number": return p[p.type] ?? "";
    case "created_time": case "last_edited_time": return p[p.type] ?? "";
    case "relation": return p.relation?.length ? `${p.relation.length} linked` : "";
    case "formula": { const f = p.formula ?? {}; return f[f.type] == null ? "" : String(f[f.type]?.start ?? f[f.type]); }
    case "rollup": { const r = p.rollup ?? {}; return r.type === "number" ? String(r.number ?? "") : r.type === "array" ? `${r.array?.length ?? 0} items` : ""; }
    case "unique_id": return p.unique_id ? `${p.unique_id.prefix ? p.unique_id.prefix + "-" : ""}${p.unique_id.number}` : "";
    default: return "";
  }
}
const parse = (text?: string) => { try { return JSON.parse(text ?? ""); } catch { return undefined; } };
async function notion(cmd: NotionCmd) {
  if (cmd.action === "update") {
    const { text: _, ...result } = await pinnedCall(cmd.prefix, "API-patch-page", { page_id: cmd.pageId, properties: cmd.properties ?? {} });
    return emit({ ev: "notion", reqId: cmd.reqId, action: "update", ...result });
  }
  const [schema, rows] = await Promise.all([
    pinnedCall(cmd.prefix, "API-retrieve-a-data-source", { data_source_id: cmd.dataSourceId }),
    pinnedCall(cmd.prefix, "API-query-data-source", { data_source_id: cmd.dataSourceId, page_size: 60 }, true),
  ]);
  const source = parse(schema.text), list = parse(rows.text);
  if (!rows.ok || !Array.isArray(list?.results)) {
    return emit({ ev: "notion", reqId: cmd.reqId, action: "query", ok: false, error: rows.error ?? schema.error ?? "Notion didn't return any rows" });
  }
  const props = Object.values(source?.properties ?? {}).map((p: any) => ({
    name: p.name, type: p.type, options: (p[p.type]?.options ?? []).map((o: any) => o.name),
  }));
  const items = list.results.filter((r: any) => r.object === "page").map((r: any) => {
    const values: Record<string, string> = {};
    let title = "";
    for (const [name, p] of Object.entries<any>(r.properties ?? {})) {
      if (p.type === "title") title = plain(p.title);
      else values[name] = propText(p);
    }
    return { id: r.id, url: r.url, title: title || "Untitled", values };
  });
  // Without the schema (no retrieve tool), fall back to the types the rows carry.
  const known = props.length ? props : Object.entries<any>(list.results[0]?.properties ?? {}).map(([name, p]) => ({ name, type: p.type, options: [] }));
  emit({ ev: "notion", reqId: cmd.reqId, action: "query", ok: true, props: known, rows: items, more: !!list.has_more });
}

// Which MCP servers (and so which accounts) exist: a session that never gets a prompt, so no model call.
async function probeServers() {
  const inbox = new Inbox();
  const q = track(query({ prompt: inbox, options: { pathToClaudeCodeExecutable: CLAUDE, cwd: WORKSPACE, persistSession: false } }));
  const drain = (async () => { try { for await (const _ of q) {} } catch {} })();
  try {
    for (const wait of [0, 4000, 8000]) {
      await new Promise((r) => setTimeout(r, wait));
      const servers = await q.mcpServerStatus();
      knownServers = servers.map((s) => s.name);
      emit({ ev: "servers", items: servers.filter((s) => s.status !== "disabled").map((s) => ({ name: s.name, status: s.status })) });
      if (!servers.some((s) => s.status === "pending")) break;
    }
  } catch (err) {
    emit({ ev: "error", message: "servers: " + String(err) });
  } finally {
    inbox.close();
    release(q);
    await drain;
  }
}

// A stray rejection must never take the sidecar (and every card's session) down: report it and keep going.
process.on("unhandledRejection", (err) => emit({ ev: "error", message: "sidecar: " + String(err) }));
process.on("uncaughtException", (err) => emit({ ev: "error", message: "sidecar: " + String(err) }));

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => void handleLine(line).catch((err) => emit({ ev: "error", message: "sidecar: " + String(err) })));

async function handleLine(line: string) {
  if (!line.trim()) return;
  let cmd: any;
  try { cmd = JSON.parse(line); } catch { return emit({ ev: "error", message: "bad json" }); }
  const card = cards.get(cmd.cardId);
  if (cmd.engine === "codex" || (cmd.cardId && codex.has(cmd.cardId))) {
    switch (cmd.op) {
      case "open": return codex.open({ cardId: cmd.cardId, cwd: cmd.cwd ?? process.cwd(), resume: cmd.resume, fork: cmd.fork, system: cmd.system });
      case "send": return codex.send(cmd.cardId, cmd.text, Array.isArray(cmd.images) ? cmd.images : []);
      case "interrupt": return codex.interrupt(cmd.cardId);
      case "close": return codex.close(cmd.cardId);
    }
  }
  switch (cmd.op) {
    case "open":
      if (card) return;
      void open({
        cardId: cmd.cardId, cwd: cmd.cwd ?? process.cwd(), model: cmd.model, resume: cmd.resume, fork: cmd.fork, system: cmd.system,
        kind: cmd.kind, permissionMode: cmd.permissionMode, autoAllowReads: cmd.autoAllowReads, keep: cmd.keep, reach: cmd.reach,
      });
      break;
    case "send":
      if (!card) return emit({ ev: "error", cardId: cmd.cardId, message: "not open" });
      card.inbox.push(cmd.text, loadImages(cmd.images));
      break;
    case "interrupt":
      if (!card) return;
      card.interrupted = true;
      await card.q.interrupt().catch(() => {});
      break;
    case "permission": {
      if (codex.answer(cmd.reqId, cmd.decision)) break;
      const p = pending.get(cmd.reqId);
      pending.delete(cmd.reqId);
      if (!p) return;
      if (cmd.decision === "deny") p.resolve({ behavior: "deny", message: cmd.note ?? "Denied by user" });
      else
        p.resolve({
          behavior: "allow",
          updatedInput: p.input,
          ...(cmd.decision === "always" && p.suggestions ? { updatedPermissions: p.suggestions } : {}),
        });
      break;
    }
    case "close":
      // A closed card's claude goes now, even mid-turn or waiting on an approval nobody will answer.
      if (!card) return;
      card.closing = true;
      for (const [reqId, p] of pending)
        if (p.cardId === cmd.cardId) { pending.delete(reqId); p.resolve({ behavior: "deny", message: "Card closed" }); }
      card.inbox.close();
      release(card.q);
      break;
    case "mail":
      void mail(cmd);
      break;
    case "slack":
      void slack(cmd);
      break;
    case "invite":
      void invite(cmd);
      break;
    case "channels":
      void channels(cmd.prefix);
      break;
    case "notion":
      void notion(cmd);
      break;
    case "suggest":
      suggester.ask(cmd.cardId, cmd.connector, cmd.transcript ?? "");
      break;
    case "servers":
      // The app's cached server list, so cards can be scoped before (or without) a probe.
      if (Array.isArray(cmd.items) && knownServers.length === 0) knownServers = cmd.items;
      break;
    case "probe":
      void probeServers();
      break;
    case "substackAuth":
      void substackAuth(cmd.cookie);
      break;
    case "substack":
      void substackSave(cmd);
      break;
  }
}

// Relay quit (stdin closed), stopped us (SIGTERM) or died: don't leave an orphan sidecar or its claude processes behind.
rl.on("close", () => shutdown("stdin closed"));
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(sig, () => shutdown(sig));
const parent = process.ppid;
setInterval(() => { try { process.kill(parent, 0); } catch { shutdown("parent gone"); } }, 30_000).unref();

// The app asks for a probe ("probe") only when its cached server list is missing or stale.
emit({ ev: "ready", claude: CLAUDE });
