// Substack through the JSON API its own web app uses (there is no public API). Relay signs in with the session
// cookie from its web view, where you sign in once and stay signed in. Cards read drafts here; a draft is only
// ever written from the card's Save button, and nothing here can publish, schedule or delete.

let cookie = "";
type Pub = { id: number; name: string; subdomain: string; customDomain?: string; role: string; primary: boolean };
type Me = { userId: number; name: string; handle: string; pubs: Pub[] };
let me: Me | undefined;

export class SignedOut extends Error { constructor() { super("Not signed in to Substack"); } }

/** The Cookie header for substack.com from Relay's web view; empty when signed out. */
export function setCookie(value: string) {
  if (value === cookie) return false;
  cookie = value;
  me = undefined;
  return true;
}

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";

async function api(host: string, path: string, init: { method?: string; body?: unknown } = {}): Promise<any> {
  if (!cookie) throw new SignedOut();
  const res = await fetch(`https://${host}/api/v1${path}`, {
    method: init.method ?? "GET",
    headers: { Cookie: cookie, "User-Agent": UA, Accept: "application/json", ...(init.body !== undefined && { "Content-Type": "application/json" }) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(30_000),
  });
  // 403 on a publication means you aren't an editor there; on substack.com itself it means the session is gone.
  if (res.status === 401 || (res.status === 403 && host === "substack.com")) { me = undefined; throw new SignedOut(); }
  if (res.status === 403) throw new Error(`You aren't an editor of ${host}`);
  if (!res.ok) throw new Error(`Substack said ${res.status}: ${(await res.text()).replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").slice(0, 160)}`);
  return res.json();
}

/** You and every publication you have a role on. */
export async function account(): Promise<Me> {
  if (me) return me;
  const p = await api("substack.com", "/user/profile/self");
  me = {
    userId: p.id, name: p.name ?? "", handle: p.handle ?? "",
    pubs: (p.publicationUsers ?? []).filter((u: any) => u?.publication).map((u: any) => ({
      id: u.publication.id, name: u.publication.name ?? u.publication.subdomain, subdomain: u.publication.subdomain,
      customDomain: u.publication.custom_domain || undefined, role: u.role ?? "", primary: !!u.is_primary,
    })),
  };
  return me;
}

const norm = (s: string) => s.toLowerCase().replace(/^https?:\/\//, "").replace(/\.substack\.com.*$/, "").replace(/[^a-z0-9]/g, "");
const describe = (pubs: Pub[]) => pubs.map((p) => `${p.name} (${p.subdomain})`).join(", ");

/** The publication you meant: by subdomain, name, custom domain, or a loose piece of one ("acme", "the studio"). */
export async function pick(name?: string): Promise<Pub> {
  const { pubs } = await account();
  if (!pubs.length) throw new Error("This Substack account doesn't run any publications.");
  if (!name?.trim()) {
    if (pubs.length === 1) return pubs[0]!;
    throw new Error(`Which publication? This account runs ${describe(pubs)}. Ask the user if it isn't clear.`);
  }
  const q = norm(name.replace(/^the\s+/i, ""));
  const keys = (p: Pub) => [p.subdomain, p.name, p.customDomain ?? ""].map(norm).filter(Boolean);
  const exact = pubs.filter((p) => keys(p).includes(q));
  if (exact.length === 1) return exact[0]!;
  const words = name.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 2 && !["the", "substack", "newsletter", "one", "pub"].includes(w));
  const loose = pubs.filter((p) => keys(p).some((k) => k.includes(q) || (k.length > 3 && q.includes(k)))
    || (words.length > 0 && words.every((w) => keys(p).some((k) => k.includes(w)))));
  if (loose.length === 1) return loose[0]!;
  if (loose.length > 1) throw new Error(`"${name}" could be ${describe(loose)}. Ask the user which.`);
  throw new Error(`No publication matches "${name}". This account runs ${describe(pubs)}.`);
}

const host = (p: Pub) => `${p.subdomain}.substack.com`;
export const editorUrl = (p: Pub, id: number) => `https://${host(p)}/publish/post/${id}`;

/** Drafts, most recently edited first. */
export async function drafts(p: Pub, limit = 15) {
  const r = await api(host(p), `/post_management/drafts?offset=0&limit=${limit}&order_by=draft_updated_at&order_direction=desc`);
  return (r.posts ?? []).map((d: any) => ({
    id: d.id as number, title: d.draft_title || "(untitled)", subtitle: d.draft_subtitle || undefined,
    updated: d.draft_updated_at as string, audience: d.audience, url: editorUrl(p, d.id),
  }));
}

/** One draft, its body as Markdown. */
export async function draft(p: Pub, id: number) {
  const d = await api(host(p), `/drafts/${id}`);
  const doc = parseBody(d.draft_body);
  return {
    id: d.id as number, title: d.draft_title ?? "", subtitle: d.draft_subtitle ?? "", markdown: toMarkdown(doc),
    updated: d.draft_updated_at as string, published: !!d.is_published, url: editorUrl(p, d.id),
  };
}

/** Save what the user edited in the card: a new draft, or over the one it came from. Never publishes. */
export async function save(cmd: { publication: string; postId?: number; title: string; subtitle?: string; body: string; synced?: string }) {
  const p = await pick(cmd.publication);
  const fields = { draft_title: cmd.title, draft_subtitle: cmd.subtitle ?? "" };
  if (cmd.postId) {
    const current = await api(host(p), `/drafts/${cmd.postId}`);
    if (current.is_published) throw new Error("That post is already published; Relay only saves drafts");
    // Edited in Substack since the card read it: don't write over that work.
    if (cmd.synced && current.draft_updated_at && current.draft_updated_at !== cmd.synced)
      throw new Error("it changed in Substack since Relay read it. Ask the card to read it again, or open it in Substack");
    const doc = fromMarkdown(cmd.body, parseBody(current.draft_body));
    const d = await api(host(p), `/drafts/${cmd.postId}`, { method: "PUT", body: { ...fields, draft_body: JSON.stringify(doc) } });
    return { postId: d.id ?? cmd.postId, updated: d.draft_updated_at as string, url: editorUrl(p, cmd.postId), pub: p.name };
  }
  const { userId } = await account();
  const d = await api(host(p), "/drafts", { method: "POST", body: {
    ...fields, draft_body: JSON.stringify(fromMarkdown(cmd.body)), type: "newsletter", audience: "everyone",
    draft_bylines: [{ id: userId, is_guest: false }],
  } });
  return { postId: d.id as number, updated: d.draft_updated_at as string, url: editorUrl(p, d.id), pub: p.name };
}

// MARK: Markdown ⇄ Substack's editor (ProseMirror JSON)

type Mark = { type: string; attrs?: Record<string, unknown> };
type Node = { type: string; text?: string; marks?: Mark[]; attrs?: Record<string, unknown>; content?: Node[] };

function parseBody(body: unknown): Node {
  if (body && typeof body === "object") return body as Node;
  try { return JSON.parse(String(body ?? "")); } catch { return { type: "doc", content: [] }; }
}

// Blocks Markdown can't say (embeds, buttons, subscribe widgets, footnotes) travel as a marker line,
// and saving puts the original block back in its place.
const KEEP = /^<!-- substack block (\d+)(?::[^>]*)? -->$/;

export function toMarkdown(doc: Node): string {
  return (doc.content ?? []).map((node, i) => block(node, i)).filter((s) => s !== "").join("\n\n");
}

function block(node: Node, index: number, depth = 0): string {
  const kids = node.content ?? [];
  switch (node.type) {
    case "paragraph": return inlineMd(kids);
    case "heading": return "#".repeat(Number(node.attrs?.level ?? 1)) + " " + inlineMd(kids);
    case "blockquote": return kids.map((k) => block(k, index, depth)).join("\n\n").split("\n").map((l) => "> " + l).join("\n");
    case "horizontal_rule": return "---";
    case "code_block": case "codeBlock":
      return "```" + String(node.attrs?.language ?? "") + "\n" + kids.map((k) => k.text ?? "").join("") + "\n```";
    case "bullet_list": case "ordered_list":
      return kids.map((item, n) => {
        const bullet = node.type === "ordered_list" ? `${n + 1}. ` : "- ";
        const body = (item.content ?? []).map((k) => block(k, index, depth + 1)).join("\n");
        return " ".repeat(depth * 2) + bullet + body.trimStart();
      }).join("\n");
    case "captionedImage": {
      const image = kids.find((k) => k.type === "image2");
      const caption = inlineMd(kids.find((k) => k.type === "caption")?.content ?? []);
      return image?.attrs?.src ? `![${caption || String(image.attrs.alt ?? "")}](${image.attrs.src})` : keep(node, index, depth);
    }
    default:
      return keep(node, index, depth);
  }
}

const keep = (node: Node, index: number, depth: number) => depth === 0 ? `<!-- substack block ${index}: ${node.type} -->` : "";

function inlineMd(nodes: Node[]): string {
  return nodes.map((n) => {
    if (n.type === "hard_break") return "\\\n";
    if (n.type !== "text") return "";
    let s = n.text ?? "";
    for (const m of n.marks ?? []) {
      if (m.type === "strong") s = `**${s}**`;
      else if (m.type === "em") s = `*${s}*`;
      else if (m.type === "code") s = "`" + s + "`";
      else if (m.type === "strikethrough") s = `~~${s}~~`;
      else if (m.type === "link") s = `[${s}](${m.attrs?.href ?? ""})`;
    }
    return s;
  }).join("");
}

export function fromMarkdown(md: string, original?: Node): Node {
  const kept = original?.content ?? [];
  const images = new Map<string, Node>();
  const collect = (n: Node) => { if (n.type === "captionedImage") { const src = n.content?.find((k) => k.type === "image2")?.attrs?.src; if (src) images.set(String(src), n); } n.content?.forEach(collect); };
  kept.forEach(collect);
  return { type: "doc", content: blocks(md.replace(/\r\n?/g, "\n").split("\n"), kept, images) };
}

function blocks(lines: string[], kept: Node[], images: Map<string, Node>): Node[] {
  const out: Node[] = [];
  let i = 0;
  const isList = (l: string) => /^\s*([-*+]|\d+[.)])\s+/.test(l);
  while (i < lines.length) {
    const line = lines[i]!;
    const trimmed = line.trim();
    if (!trimmed) { i++; continue; }
    const keep = trimmed.match(KEEP);
    if (keep) { const node = kept[Number(keep[1])]; if (node) out.push(node); i++; continue; }
    const fence = trimmed.match(/^(```|~~~)\s*([\w+-]*)/);
    if (fence) {
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i]!.trim().startsWith(fence[1]!)) code.push(lines[i++]!);
      i++;
      out.push({ type: "codeBlock", ...(fence[2] && { attrs: { language: fence[2] } }), ...(code.length && { content: [{ type: "text", text: code.join("\n") }] }) });
      continue;
    }
    const heading = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (heading) { out.push({ type: "heading", attrs: { level: heading[1]!.length }, content: inline(heading[2]!) }); i++; continue; }
    if (/^(\*\s*\*\s*\*|-\s*-\s*-|_\s*_\s*_)[\s*_-]*$/.test(trimmed)) { out.push({ type: "horizontal_rule" }); i++; continue; }
    const image = trimmed.match(/^!\[([^\]]*)\]\((\S+?)(?:\s+"[^"]*")?\)$/);
    if (image) {
      const known = images.get(image[2]!);
      out.push(known ?? { type: "paragraph", content: inline(`[${image[1] || image[2]}](${image[2]})`) });
      i++; continue;
    }
    if (trimmed.startsWith(">")) {
      const quoted: string[] = [];
      while (i < lines.length && lines[i]!.trim().startsWith(">")) quoted.push(lines[i++]!.trim().replace(/^>\s?/, ""));
      out.push({ type: "blockquote", content: blocks(quoted, kept, images) });
      continue;
    }
    if (isList(line)) {
      const indent = line.match(/^\s*/)![0].length;
      const ordered = /^\s*\d/.test(line);
      const items: Node[] = [];
      while (i < lines.length && isList(lines[i]!) && lines[i]!.match(/^\s*/)![0].length === indent && /^\s*\d/.test(lines[i]!) === ordered) {
        const first = lines[i++]!.replace(/^\s*([-*+]|\d+[.)])\s+/, "");
        const rest: string[] = [];
        // The item's own wrapped lines and anything indented deeper (a nested list) belong to it.
        while (i < lines.length && lines[i]!.trim() && (lines[i]!.match(/^\s*/)![0].length > indent || !isList(lines[i]!) && !/^\s*(#|>|```)/.test(lines[i]!))) rest.push(lines[i++]!);
        const nestedAt = rest.findIndex(isList);
        const text = [first, ...(nestedAt < 0 ? rest : rest.slice(0, nestedAt))].map((l) => l.trim()).join(" ");
        const nested = nestedAt < 0 ? [] : blocks(rest.slice(nestedAt), kept, images);
        items.push({ type: "list_item", content: [{ type: "paragraph", content: inline(text) }, ...nested] });
      }
      out.push({ type: ordered ? "ordered_list" : "bullet_list", content: items });
      continue;
    }
    const para: string[] = [];
    while (i < lines.length && lines[i]!.trim() && !isList(lines[i]!) && !/^\s*(#{1,6}\s|>|```|~~~)/.test(lines[i]!) && !KEEP.test(lines[i]!.trim())) para.push(lines[i++]!);
    out.push({ type: "paragraph", content: paragraph(para) });
  }
  return out;
}

/** Lines of one paragraph: soft breaks become spaces; a trailing backslash or two spaces is a line break. */
function paragraph(lines: string[]): Node[] {
  const out: Node[] = [];
  lines.forEach((line, n) => {
    const hard = /(\\|  )$/.test(line);
    const text = line.trim().replace(/\\$/, "");
    out.push(...inline(n < lines.length - 1 && !hard ? text + " " : text));
    if (hard && n < lines.length - 1) out.push({ type: "hard_break" });
  });
  return out;
}

const INLINE = /(`+)([^`]+?)\1|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|(\*\*|__)(?=\S)(.+?\S)\5|~~(?=\S)(.+?\S)~~|(\*|_)(?=\S)(.+?\S)\8/g;

export function inline(text: string, marks: Mark[] = []): Node[] {
  const out: Node[] = [];
  const push = (s: string, m: Mark[]) => { if (s) out.push({ type: "text", text: s, ...(m.length && { marks: m }) }); };
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    const at = m.index!;
    // snake_case and 2*3*4 aren't emphasis: an underscore or star run needs a non-word character outside it.
    if ((m[5] === "__" || m[8] === "_") && (/\w/.test(text[at - 1] ?? "") || /\w/.test(text[at + m[0].length] ?? ""))) continue;
    push(text.slice(last, at), marks);
    if (m[1]) push(m[2]!, [...marks, { type: "code" }]);
    else if (m[3]) out.push(...inline(m[3], [...marks, { type: "link", attrs: { href: m[4] } }]));
    else if (m[5]) out.push(...inline(m[6]!, [...marks, { type: "strong" }]));
    else if (m[7]) out.push(...inline(m[7], [...marks, { type: "strikethrough" }]));
    else if (m[8]) out.push(...inline(m[9]!, [...marks, { type: "em" }]));
    last = at + m[0].length;
  }
  push(text.slice(last), marks);
  return out;
}
