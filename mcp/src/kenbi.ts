// Locate and run the kenbi binary, returning its stable JSON findings.
//
// The MCP server is a thin, loosely-coupled wrapper: it never imports kenbi
// source, it only spawns the built binary and parses `--format=json`. The core
// checker therefore has zero dependency on this directory.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

export interface Finding {
  file: string;
  line: number;
  code: string;
  severity: string;
  message: string;
}

export interface AxisScope {
  /** `file`: every function; `functions`: some (the rest are in `unchecked`); `off`: none. */
  mode: "file" | "functions" | "off";
  checked: number;
  unchecked: string[];
}

/** What kenbi checked in one analysed file, axis by axis. */
export interface FileScope {
  file: string;
  functions: number;
  axes: Record<string, AxisScope>;
  ownershipBlocks: { first: number; last: number }[];
}

export interface Coverage {
  memoryFunctions: number;
  green: number;
  verified: number;
  adopted: number;
  red: number;
  blocksAdopted: number;
  trustedFrontier: string[];
  unsafeVouches: { function: string; line: number }[];
}

export interface KenbiResult {
  version: number;
  tool: string;
  findings: Finding[];
  coverage?: Coverage;
  scope?: FileScope[];
}

export interface RunOptions {
  compileCommands?: string;
  clangArgs?: string[];
  /** Working directory kenbi runs in; relative `files` resolve against it. */
  cwd?: string;
  /** Hard wall-clock limit in ms; the child is killed if it overruns. */
  timeoutMs?: number;
}

/** Default analysis timeout (ms); override per-call or via $KENBI_TIMEOUT_MS. */
export function defaultTimeoutMs(): number {
  const env = Number(process.env.KENBI_TIMEOUT_MS);
  return Number.isFinite(env) && env > 0 ? env : 60_000;
}

/** Resolve the kenbi binary: $KENBI_BIN, then the repo-root build, then PATH. */
export function resolveKenbiBin(): string {
  if (process.env.KENBI_BIN) return process.env.KENBI_BIN;
  // dist/index.js lives at <repo>/mcp/dist; the built binary at <repo>/kenbi.
  const here = dirname(fileURLToPath(import.meta.url)); // .../mcp/dist
  const repoBin = resolve(here, "..", "..", "kenbi"); // .../kenbi
  if (existsSync(repoBin)) return repoBin;
  return "kenbi"; // fall back to PATH
}

/**
 * Run kenbi over `files` and return the parsed JSON document. kenbi always
 * prints a complete JSON document on stdout — clean (exit 0), issues found
 * (exit 1) and even usage/parse failures (exit 2, surfaced as PARSE_ERROR
 * findings) — so the exit status is informational, not a parse gate.
 */
export function runKenbi(files: string[], opts: RunOptions = {}): KenbiResult {
  const bin = resolveKenbiBin();
  const args = ["--format=json"];
  if (opts.compileCommands) args.push(`--compile-commands=${opts.compileCommands}`);
  // kenbi reads any argument that starts with `-` as an option, so a file named that way is
  // passed as a path (`./-x.c`) and can never be taken for a flag.
  args.push(...files.map((f) => (f.startsWith("-") ? `./${f}` : f)));
  if (opts.clangArgs && opts.clangArgs.length > 0) args.push("--", ...opts.clangArgs);

  const timeout = opts.timeoutMs && opts.timeoutMs > 0 ? opts.timeoutMs : defaultTimeoutMs();
  const res = spawnSync(bin, args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    cwd: opts.cwd, // relative `files` resolve here; undefined => the server's cwd
    timeout, // kill a runaway analysis rather than hang the client
    killSignal: "SIGTERM",
  });
  if (res.error) {
    const code = (res.error as NodeJS.ErrnoException).code;
    if (code === "ETIMEDOUT") {
      throw new Error(`kenbi timed out after ${timeout}ms on ${files.length} file(s)`);
    }
    throw new Error(`failed to run kenbi (${bin}): ${res.error.message}`);
  }
  if (res.signal) {
    const why = res.signal === "SIGTERM" ? ` (likely the ${timeout}ms timeout)` : "";
    throw new Error(`kenbi was killed by signal ${res.signal}${why}`);
  }
  const out = (res.stdout ?? "").trim();
  if (out.length === 0) {
    const err = res.stderr ? `: ${res.stderr.trim()}` : "";
    throw new Error(`kenbi produced no output (exit ${res.status})${err}`);
  }
  try {
    return JSON.parse(out) as KenbiResult;
  } catch (e) {
    throw new Error(`could not parse kenbi output: ${(e as Error).message}\n${out}`);
  }
}
