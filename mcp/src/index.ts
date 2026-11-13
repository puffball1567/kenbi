#!/usr/bin/env node
// kenbi MCP server — exposes the deterministic memory-safety checker as a
// callable tool, plus the annotation reference as a resource, so an agent checks C/C++
// while it writes it: the agent writes annotated C/C++, calls `check_memory_safety`, and
// fixes until kenbi reports no findings. The deterministic checker stays the judge;
// annotations are claims it verifies.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { runKenbi } from "./kenbi.js";
import { summarize } from "./summary.js";
import { ANNOTATIONS } from "./annotations.js";
import { PATTERNS } from "./patterns.js";
import { FINDINGS, type FindingEntry } from "./generated/findings.js";

const server = new McpServer({ name: "kenbi-mcp", version: "0.1.1" });

server.registerTool(
  "check_memory_safety",
  {
    title: "Check C/C++ memory safety (kenbi)",
    description:
      "Run the kenbi deterministic memory-safety checker on C/C++ source files and return its findings. " +
      "kenbi verifies the code against its `@`-annotations (ownership / free / move / copy / nullable / " +
      "must_use / frees-contract) — the annotations are NOT trusted; the implementation is checked against " +
      "them. Run this after writing or editing annotated C/C++ to confirm the declared intent holds, and " +
      "re-run until it reports no findings. A result without findings covers only the scope its summary " +
      "lists — which checks ran on which functions, and what it rests on without checking. Do not " +
      "repeat in ordinary comments what an annotation already declares: the annotation is checked, " +
      "the prose copy is not. Read the `kenbi://annotations` resource for how to annotate, and " +
      "`kenbi://patterns` for the canonical safe shapes kenbi declares GREEN (and the unsafe " +
      "ones it rejects) for each bug class.",
    inputSchema: {
      files: z
        .array(z.string())
        .min(1)
        .describe("Paths to C/C++ source files to check (.c/.cc/.cpp/.cxx)."),
      compileCommands: z
        .string()
        .optional()
        .describe("Path to a compile_commands.json for include paths/flags (auto-discovered upward if omitted)."),
      clangArgs: z
        .array(z.string())
        .optional()
        .describe("Extra clang arguments, e.g. ['-Iinclude'], passed after `--`."),
      cwd: z
        .string()
        .optional()
        .describe("Working directory to resolve relative file/compile-commands paths against (so the result does not depend on where the MCP client launched the server)."),
      timeoutMs: z
        .number()
        .int()
        .positive()
        .optional()
        .describe("Hard wall-clock limit in ms; a runaway analysis is killed instead of hanging the client (default 60000, or $KENBI_TIMEOUT_MS)."),
    },
  },
  async ({ files, compileCommands, clangArgs, cwd, timeoutMs }) => {
    let result;
    try {
      result = runKenbi(files, { compileCommands, clangArgs, cwd, timeoutMs });
    } catch (e) {
      return {
        isError: true,
        content: [{ type: "text", text: (e as Error).message }],
      };
    }
    const summary = summarize(result, files.length);
    return {
      content: [
        { type: "text", text: summary },
        { type: "text", text: "```json\n" + JSON.stringify(result, null, 2) + "\n```" },
      ],
    };
  }
);

server.registerResource(
  "annotations",
  "kenbi://annotations",
  {
    title: "kenbi annotation reference",
    description: "How to annotate C/C++ for kenbi (the directives the checker verifies).",
    mimeType: "text/markdown",
  },
  async (uri) => ({
    contents: [{ uri: uri.href, mimeType: "text/markdown", text: ANNOTATIONS }],
  })
);

server.registerResource(
  "patterns",
  "kenbi://patterns",
  {
    title: "kenbi-verified safe patterns (C/C++)",
    description:
      "Canonical memory-safe C/C++ idioms kenbi declares GREEN, paired with the unsafe shapes " +
      "it rejects and why, per bug class (double-free / use-after-free / leak / non-heap / " +
      "interior / cross-function ownership). Grounding for writing or fixing C/C++ that passes " +
      "check_memory_safety. Distilled from the three-state Juliet demonstration.",
    mimeType: "text/markdown",
  },
  async (uri) => ({
    contents: [{ uri: uri.href, mimeType: "text/markdown", text: PATTERNS }],
  })
);

// explain_finding — the write→check→FIX loop closer. Given a finding code from
// check_memory_safety (or a CWE), returns the verified A/B/C worked example for that class.
function renderEntry(code: string, e: FindingEntry): string {
  const state = (label: string, s: { code: string; why: string }) =>
    `## ${label}\n\`\`\`c\n${s.code}\`\`\`\nWhy: ${s.why}\n`;
  const prov = e.provenance
    ? `\nProvenance: ${e.provenance.cve} — ${e.provenance.project} (fix: ${e.provenance.url})`
    : "";
  return (
    `# Fixing \`${code}\`  (${e.cwe} · ${e.axis} axis · contracts: ${e.contracts.join(", ") || "none"})\n` +
    `Intent: ${e.intent}. ${e.title}.${prov}\n\n` +
    state("A — what triggers it (RED)", e.A) + "\n" +
    state("B — why a half-fix stays RED", e.B) + "\n" +
    state("C — the fix (GREEN)", e.C) +
    `\nApply the C shape, then re-run \`check_memory_safety\` to confirm GREEN.`
  );
}

server.registerTool(
  "explain_finding",
  {
    title: "Explain & fix a kenbi finding",
    description:
      "Given a kenbi finding CODE from check_memory_safety (e.g. \"WRONG_DEALLOCATOR\", " +
      "\"LOCK_ORDER_VIOLATION\", \"UNVALIDATED_INDEX\") or a CWE id (\"CWE-762\"), return a worked " +
      "three-state example: A what triggers it (RED), B why a half-fix stays RED, C the fix " +
      "(GREEN), plus the contract to declare. Call this whenever check_memory_safety reports a " +
      "finding you need to resolve; write to the C shape and re-run check_memory_safety until " +
      "it reports no findings. The examples come from the three-state corpus, whose every state " +
      "is checked against kenbi; for a code the corpus does not cover it lists the codes it does.",
    inputSchema: {
      code: z
        .string()
        .describe("A kenbi finding code (e.g. \"NULL_DEREF\") or a CWE id (e.g. \"CWE-476\")."),
    },
  },
  async ({ code }) => {
    const key = code.trim().toUpperCase();
    let entries: FindingEntry[];
    if (key.startsWith("CWE")) {
      const cwe = key.replace(/^CWE-?/, "CWE-");
      const seen = new Set<string>();
      entries = [];
      for (const list of Object.values(FINDINGS))
        for (const e of list)
          if (e.cwe.toUpperCase() === cwe && !seen.has(e.id)) {
            seen.add(e.id);
            entries.push(e);
          }
    } else {
      entries = FINDINGS[key] ?? [];
    }
    if (entries.length === 0) {
      const known = Object.keys(FINDINGS).sort().join(", ");
      return {
        content: [
          {
            type: "text",
            text:
              `No worked A/B/C example for \`${code}\`. kenbi has fix examples for these finding ` +
              `codes:\n${known}\n\nSee \`kenbi://annotations\` for the directive reference and ` +
              `\`kenbi://patterns\` for the safe shapes by intent.`,
          },
        ],
      };
    }
    const text = entries
      .map((e) => renderEntry(key.startsWith("CWE") ? e.class[0] : key, e))
      .join("\n\n---\n\n");
    return { content: [{ type: "text", text }] };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
