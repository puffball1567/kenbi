// End-to-end: spawn the built MCP server over stdio and exercise it as a real
// MCP client. Requires `npm run build` and a built kenbi binary at <repo>/kenbi
// (or $KENBI_BIN). Run with: node --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { copyFileSync, mkdirSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const here = dirname(fileURLToPath(import.meta.url)); // mcp/test
const repoRoot = resolve(here, "..", ".."); // kenbi/
const serverEntry = resolve(here, "..", "dist", "index.js");
const kenbiBin = resolve(repoRoot, "kenbi");

async function connect() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    env: { ...process.env, KENBI_BIN: kenbiBin },
  });
  const client = new Client({ name: "kenbi-mcp-test", version: "0.0.0" });
  await client.connect(transport);
  return client;
}

const text = (r) => r.content.map((c) => c.text ?? "").join("\n");

test("lists the check_memory_safety tool", async () => {
  const c = await connect();
  const { tools } = await c.listTools();
  assert.ok(tools.some((t) => t.name === "check_memory_safety"), "tool present");
  await c.close();
});

test("flags a discarded @must_use result", async () => {
  const c = await connect();
  const r = await c.callTool({
    name: "check_memory_safety",
    arguments: { files: [resolve(repoRoot, "tests/c/t38_must_use_discarded.c")] },
  });
  assert.match(text(r), /UNUSED_MUST_USE/);
  await c.close();
});

test("flags a double free", async () => {
  const c = await connect();
  const r = await c.callTool({
    name: "check_memory_safety",
    arguments: { files: [resolve(repoRoot, "tests/c/t01_double_free.c")] },
  });
  assert.match(text(r), /DOUBLE_FREE/);
  await c.close();
});

test("resolves relative paths against the cwd option", async () => {
  const c = await connect();
  const r = await c.callTool({
    name: "check_memory_safety",
    arguments: { files: ["tests/c/t01_double_free.c"], cwd: repoRoot },
  });
  assert.match(text(r), /DOUBLE_FREE/);
  await c.close();
});

test("a file whose name starts with '-' is analysed, not taken for an option", async () => {
  const dir = resolve(repoRoot, "tmp", "mcp-dash-name");
  mkdirSync(dir, { recursive: true });
  copyFileSync(resolve(repoRoot, "tests/c/t01_double_free.c"), resolve(dir, "-double_free.c"));
  const c = await connect();
  try {
    const r = await c.callTool({
      name: "check_memory_safety",
      arguments: { files: ["-double_free.c"], cwd: dir },
    });
    assert.match(text(r), /DOUBLE_FREE/);
  } finally {
    await c.close();
  }
});

async function summaryOf(file) {
  const c = await connect();
  try {
    const r = await c.callTool({ name: "check_memory_safety", arguments: { files: [file] } });
    return r.content[0].text;
  } finally {
    await c.close();
  }
}

test("a finding-free result states its scope, never just 'clean'", async () => {
  const s = await summaryOf(resolve(repoRoot, "tests/c/t07_ok.c"));
  assert.match(s, /^kenbi: no findings in 1 file\(s\) from the checks that ran/);
  assert.doesNotMatch(s, /\bclean\b|\bsafe\b/);
  assert.match(s, /ownership, lifetime and null .*: checked in every function/);
  assert.match(s, /NOT checked anywhere: bounds \(`@spatial`\); locks \(`@threadsafe`\); initialisation/);
  assert.match(s, /no function is adopted with `@kenbi`, so nothing here is `verified`/);
});

test("functions outside @kenbi are named as unchecked", async () => {
  const s = await summaryOf(resolve(here, "fixtures", "partly_adopted.c"));
  assert.match(s, /^kenbi: no findings/);
  assert.match(s, /checked in 1 of 2 functions; NOT checked in partly_adopted\.c: not_adopted/);
});

test("a GREEN resting on trust names what it rests on", async () => {
  const s = await summaryOf(resolve(here, "fixtures", "trusted.c"));
  assert.match(s, /verified \(nothing taken on trust\): 0 of 2/);
  assert.match(s, /bodies were not analysed: release_elsewhere/);
  assert.match(s, /`@unsafe` \(asserted by the author, not checked\): vouched \(line 17\)/);
});

test("a result with findings carries the scope too", async () => {
  const s = await summaryOf(resolve(repoRoot, "tests/c/t01_double_free.c"));
  assert.match(s, /DOUBLE_FREE/);
  assert.match(s, /Scope — the result covers only this:/);
});

test("exposes the annotations resource", async () => {
  const c = await connect();
  const { resources } = await c.listResources();
  assert.ok(resources.some((r) => r.uri === "kenbi://annotations"), "resource listed");
  const r = await c.readResource({ uri: "kenbi://annotations" });
  assert.match(r.contents[0].text, /@must_use/);
  await c.close();
});

test("tells the agent not to restate annotations in ordinary comments", async () => {
  const c = await connect();
  try {
    const { tools } = await c.listTools();
    const tool = tools.find((t) => t.name === "check_memory_safety");
    assert.match(tool.description, /Do not repeat in ordinary comments what an annotation already declares/);
    const r = await c.readResource({ uri: "kenbi://annotations" });
    assert.match(r.contents[0].text, /not `free\(p\);  \/\* release the buffer \*\/`/);
  } finally {
    await c.close();
  }
});

test("exposes the safe-patterns resource", async () => {
  const c = await connect();
  const { resources } = await c.listResources();
  assert.ok(resources.some((r) => r.uri === "kenbi://patterns"), "patterns resource listed");
  const r = await c.readResource({ uri: "kenbi://patterns" });
  assert.match(r.contents[0].text, /FREE_INTERIOR/);
  // the resource is the curated intro/deep-dive + the generated intent-indexed catalogue
  // (single corpus); it grounds the agent for every axis/class, indexed by intent.
  assert.match(r.contents[0].text, /indexed by intent/);
  assert.match(r.contents[0].text, /Hand ownership to a callee that frees it/); // an intent header
  assert.match(r.contents[0].text, /LOCK_ORDER_VIOLATION/); // concurrency, generated
  assert.match(r.contents[0].text, /UNVALIDATED_SIZE/); // spatial size sink, generated
  assert.match(r.contents[0].text, /real: CVE-2014-0160/); // Heartbleed surfaced as a real CVE
  await c.close();
});

test("lists the explain_finding tool", async () => {
  const c = await connect();
  const { tools } = await c.listTools();
  assert.ok(tools.some((t) => t.name === "explain_finding"), "explain_finding present");
  await c.close();
});

test("explain_finding returns an A/B/C example for a finding code", async () => {
  const c = await connect();
  const r = await c.callTool({ name: "explain_finding", arguments: { code: "WRONG_DEALLOCATOR" } });
  const t = text(r);
  assert.match(t, /Fixing `WRONG_DEALLOCATOR`/);
  assert.match(t, /A — what triggers it \(RED\)/);
  assert.match(t, /B — why a half-fix stays RED/);
  assert.match(t, /C — the fix \(GREEN\)/);
  assert.match(t, /g_free/); // the C shape uses the declared deallocator
  await c.close();
});

test("explain_finding surfaces real-CVE provenance", async () => {
  const c = await connect();
  const r = await c.callTool({ name: "explain_finding", arguments: { code: "USE_AFTER_FREE" } });
  const t = text(r);
  assert.match(t, /Provenance:/);      // a real-CVE entry carries provenance
  assert.match(t, /CVE-2018-16840/);   // curl Curl_close use-after-free
  await c.close();
});

test("explain_finding resolves a CWE id", async () => {
  const c = await connect();
  const r = await c.callTool({ name: "explain_finding", arguments: { code: "CWE-833" } });
  const t = text(r);
  // CWE-833 has two entries (self-deadlock + lock-order); both should surface
  assert.match(t, /DOUBLE_LOCK/);
  assert.match(t, /LOCK_ORDER_VIOLATION/);
  await c.close();
});

test("explain_finding on an unknown code lists what it covers (not an error)", async () => {
  const c = await connect();
  const r = await c.callTool({ name: "explain_finding", arguments: { code: "NOPE" } });
  assert.ok(!r.isError, "unknown code is not an error (must not derail the fix loop)");
  assert.match(text(r), /No worked A\/B\/C example/);
  await c.close();
});
