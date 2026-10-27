// Day 0 checks: drives the sidecar exactly like the Swift app will, over JSON lines.
import { spawn } from "node:child_process";
import { mkdtempSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const work = mkdtempSync(join(tmpdir(), "relay-spike-"));
const child = spawn("bun", ["run", join(import.meta.dir, "index.ts")], { stdio: ["pipe", "pipe", "inherit"] });
const send = (o: object) => child.stdin.write(JSON.stringify(o) + "\n");

type Ev = Record<string, any>;
const waiters: { pred: (e: Ev) => boolean; resolve: (e: Ev) => void }[] = [];
createInterface({ input: child.stdout }).on("line", (l) => {
  const e = JSON.parse(l) as Ev;
  if (e.ev !== "delta") console.log("  ←", JSON.stringify(e).slice(0, 220));
  for (const w of [...waiters]) if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(e); }
});
const next = (pred: (e: Ev) => boolean, ms = 120_000) =>
  Promise.race([
    new Promise<Ev>((resolve) => waiters.push({ pred, resolve })),
    new Promise<Ev>((_, rej) => setTimeout(() => rej(new Error("timeout")), ms)),
  ]);

const results: [string, boolean, string][] = [];
const check = (name: string, ok: boolean, detail = "") => results.push([name, ok, detail]);

try {
  await next((e) => e.ev === "ready");

  // 1 + 2: login & connectors, streaming text
  send({ op: "open", cardId: "A", cwd: work, model: "haiku" });
  send({ op: "send", cardId: "A", text: "Say hello in five words." });
  const init = await next((e) => e.ev === "init" && e.cardId === "A");
  check("Uses claude.ai login (no API key)", init.apiKeySource === "none", `apiKeySource=${init.apiKeySource}`);
  let deltas = 0;
  const countDeltas = (e: Ev) => { if (e.ev === "delta" && e.cardId === "A") deltas++; return false; };
  waiters.push({ pred: countDeltas, resolve: () => {} });
  const d1 = await next((e) => e.ev === "done" && e.cardId === "A");
  check("Streams token deltas", deltas > 1, `${deltas} deltas, $${d1.costUsd?.toFixed(4)} est.`);

  // 3: approval round-trip
  send({ op: "send", cardId: "A", text: "Use the Write tool to create hello.txt containing exactly: hi from relay" });
  const perm = await next((e) => e.ev === "needsPermission" && e.cardId === "A");
  check("canUseTool approval reaches the app", perm.tool === "Write", `tool=${perm.tool}`);
  send({ op: "permission", reqId: perm.reqId, decision: "allow" });
  await next((e) => e.ev === "done" && e.cardId === "A");
  const f = join(work, "hello.txt");
  check("Approved tool actually ran", existsSync(f) && readFileSync(f, "utf8").includes("hi from relay"));

  // 4: interrupt mid-stream
  send({ op: "send", cardId: "A", text: "Count from 1 to 300, one number per line, no other text." });
  await next((e) => e.ev === "delta" && e.cardId === "A");
  const t0 = Date.now();
  send({ op: "interrupt", cardId: "A" });
  const d2 = await next((e) => e.ev === "done" && e.cardId === "A", 30_000);
  check("Interrupt stops a running turn", Date.now() - t0 < 10_000, `${Date.now() - t0}ms, subtype=${d2.subtype}`);
  const sessionId = d2.sessionId;
  send({ op: "send", cardId: "A", text: "Reply with exactly: still here" });
  const d2b = await next((e) => e.ev === "done" && e.cardId === "A");
  check("Card keeps working after interrupt", /still here/i.test(d2b.result ?? ""), `answer=${JSON.stringify(d2b.result)}`);
  send({ op: "close", cardId: "A" });
  await next((e) => e.ev === "closed" && e.cardId === "A");

  // 5: resume in a fresh card (what a relaunch does)
  send({ op: "open", cardId: "B", cwd: work, model: "haiku", resume: sessionId });
  send({ op: "send", cardId: "B", text: "What file did you create earlier? Answer with just the filename." });
  const d3 = await next((e) => e.ev === "done" && e.cardId === "B");
  check("Resume keeps history", /hello\.txt/.test(d3.result ?? ""), `answer=${JSON.stringify(d3.result)}`);
  send({ op: "close", cardId: "B" });
  send({ op: "suggest", cardId: "S", connector: "Gmail", transcript: "user: any emails from Marc?\nassistant: Two — the board deck deadline and a headcount question." });
  const sug = await next((e) => e.ev === "suggestions" && e.cardId === "S");
  check("Suggestions (Haiku, structured)", sug.items?.length === 3, JSON.stringify(sug.items));
} catch (err) {
  check("Run completed", false, String(err));
}

console.log("\nDay 0 results");
for (const [n, ok, d] of results) console.log(`${ok ? "PASS" : "FAIL"}  ${n}${d ? "  — " + d : ""}`);
console.log(`\nworkdir: ${work}`);
child.kill();
process.exit(results.every((r) => r[1]) ? 0 : 1);
