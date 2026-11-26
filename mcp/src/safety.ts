// The configured checks (`kenbi --safety=project.json`): run them, and say in a few lines what
// the result does and does not establish. As for the ordinary check, an agent may read only
// the summary, so the summary carries the scope: what was asked, what was decided, and what a
// result that passes rests on.

import { spawnSync } from "node:child_process";
import { defaultTimeoutMs, resolveKenbiBin } from "./kenbi.js";

export interface SafetyFinding {
  code: string;
  status: string;
  message: string;
  file: string;
  line: number;
  callChain?: string[];
}

export interface SafetyObligation {
  file: string;
  function: string;
  profile: string;
  forbid: string[];
  status: string;
  assumptions: string[];
  findings: SafetyFinding[];
}

export interface SafetyResult {
  kind: string;
  project?: string;
  status: string;
  accepted: boolean;
  obligations?: SafetyObligation[];
  findings: SafetyFinding[];
}

/** What resolves each finding of the configured checks. */
export const SAFETY_FIXES: Record<string, string> = {
  FORBIDDEN_EFFECT:
    "The function, or something it calls, may perform an effect its profile forbids. The call " +
    "chain in the finding ends at the call that does. Remove that call from the checked " +
    "function's closure (do the work before entering the interrupt or no-heap region, or pass in " +
    "a buffer instead of allocating). Do not change the contract of the callee to hide it: a " +
    "contract is checked against the callee's body where that is among the sources.",
  MISSING_EFFECT_CONTRACT:
    "A function without a body in the analysed sources has no effect contract, so nothing is " +
    "known about what it does. Add its source to the project's `sources`, or declare it in a " +
    "contracts file: `{\"symbol\": \"c:@F@name\", \"effects\": [...], \"assumption\": \"id\"}` and " +
    "accept the assumption in the project file. For the C string functions and compiler " +
    "builtins, add the shipped `contracts/c-library.contracts.json`.",
  UNRESOLVED_EFFECT_CALL:
    "A call through a function pointer whose targets the source does not settle. The finding " +
    "names the pointer's symbol. If the pointer is a parameter, pass the function by name at " +
    "the call sites (kenbi follows what is passed). Otherwise declare an effect contract for " +
    "that symbol — a struct field (`c:@S@config@FI@read`) or a parameter " +
    "(`c:@F@walk@param:visit`): it covers every function the pointer may hold, and is checked " +
    "against every function the sources store in it.",
  INCOMPLETE_EFFECT_CONTRACT:
    "kenbi knows this function allocates, but not whether it also blocks or waits. Declare a " +
    "contract for it that lists `heap_allocate` and whatever else it does.",
  UNSUPPORTED_EFFECT_MODEL:
    "A construct whose effects kenbi does not model (inline assembly, a `sizeof` of a variable " +
    "length array, a cleanup attribute, C++ implicit calls). The obligation stays unverified " +
    "rather than passing. Move the construct out of the checked closure.",
  CONTRACT_EFFECT_MISMATCH:
    "A contract says less than the code does: the function it describes — or a function stored " +
    "in the pointer it describes — may perform an effect the contract does not declare. Fix " +
    "the code, or correct the contract to what the function really does (the profile is then " +
    "checked against that).",
  CONTRACT_BODY_UNVERIFIED:
    "A contract could not be checked against the function it covers, because that function's " +
    "own effects are not established. Resolve the findings inside that function first.",
  CONTRACT_STORE_UNKNOWN:
    "Something that is not a named function is stored in a function pointer that has a " +
    "contract, so the contract cannot be checked against it. Store a function by name.",
  UNACCEPTED_ASSUMPTION:
    "The result depends on a contract whose assumption the project file does not accept. Add " +
    "the assumption id to `acceptedAssumptions` only if a person has decided it holds.",
  SAFETY_INPUT_ERROR:
    "The project or a contract file is not usable as written: an unknown key, a symbol that " +
    "matches nothing, a profile that does not exist, a source that does not parse. Nothing was " +
    "checked. Fix the file the message names.",
};

export function runKenbiSafety(project: string, opts: { cwd?: string; timeoutMs?: number } = {}): SafetyResult {
  const bin = resolveKenbiBin();
  const timeout = opts.timeoutMs && opts.timeoutMs > 0 ? opts.timeoutMs : defaultTimeoutMs();
  const res = spawnSync(bin, ["--format=json", `--safety=${project}`], {
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
    cwd: opts.cwd,
    timeout,
    killSignal: "SIGTERM",
  });
  if (res.error) {
    const code = (res.error as NodeJS.ErrnoException).code;
    if (code === "ETIMEDOUT") throw new Error(`kenbi timed out after ${timeout}ms on ${project}`);
    throw new Error(`failed to run kenbi (${bin}): ${res.error.message}`);
  }
  if (res.signal) throw new Error(`kenbi was killed by signal ${res.signal}`);
  const out = (res.stdout ?? "").trim();
  if (out.length === 0) {
    const err = res.stderr ? `: ${res.stderr.trim()}` : "";
    throw new Error(`kenbi produced no output (exit ${res.status})${err}`);
  }
  try {
    return JSON.parse(out) as SafetyResult;
  } catch (e) {
    throw new Error(`could not parse kenbi output: ${(e as Error).message}`);
  }
}

const base = (path: string) => path.split(/[\\/]/).pop() ?? path;
const last = (chain?: string[]) => {
  const tail = chain && chain.length > 0 ? chain[chain.length - 1] : "";
  return tail.includes("#") ? tail.split("#").pop() ?? tail : tail;
};

/** At most this many findings are spelled out per code; the JSON has them all. */
const MAX_PER_CODE = 5;

export function summarizeSafety(r: SafetyResult): string {
  const lines: string[] = [];
  const obligations = r.obligations ?? [];
  if (obligations.length === 0) {
    lines.push("kenbi --safety checked NOTHING: the input was refused.");
    for (const f of r.findings) lines.push(`  ${f.code}: ${f.message}`);
    if (r.findings.some((f) => f.code in SAFETY_FIXES)) lines.push("", SAFETY_FIXES.SAFETY_INPUT_ERROR);
    return lines.join("\n");
  }
  const by = (s: string) => obligations.filter((o) => o.status === s);
  const verified = by("verified"), conditional = by("conditional");
  const unverified = by("unverified"), violation = by("violation");
  lines.push(
    `kenbi --safety: ${r.accepted ? "ACCEPTED" : "NOT ACCEPTED"} — ${obligations.length} obligation(s): ` +
      `${violation.length} violation, ${unverified.length} unverified, ` +
      `${conditional.length} conditional, ${verified.length} verified.`
  );
  const show = (title: string, list: SafetyObligation[]) => {
    if (list.length === 0) return;
    lines.push(title);
    for (const o of list.slice(0, 20)) lines.push(`  - ${o.function} [${o.profile}: forbids ${o.forbid.join(", ")}]`);
    if (list.length > 20) lines.push(`  - … and ${list.length - 20} more (see the JSON)`);
  };
  show("Violations — the code does what the profile forbids:", violation);
  show("Unverified — kenbi could not decide; this is NOT a pass:", unverified);

  const codes = new Map<string, SafetyFinding[]>();
  for (const f of r.findings) codes.set(f.code, [...(codes.get(f.code) ?? []), f]);
  if (codes.size > 0) lines.push("", "Findings:");
  for (const [code, list] of codes) {
    lines.push(`- ${code} (${list.length})`);
    const seen = new Set<string>();
    for (const f of list) {
      const key = `${f.message}|${f.file}|${f.line}`;
      if (seen.has(key)) continue;
      seen.add(key);
      if (seen.size > MAX_PER_CODE) {
        lines.push(`    … more in the JSON`);
        break;
      }
      const at = f.file ? `${base(f.file)}:${f.line}` : "";
      const via = last(f.callChain);
      lines.push(`    ${at}  ${f.message}${via ? `  [reached through ${via}]` : ""}`);
    }
    if (code in SAFETY_FIXES) lines.push(`    To resolve: ${SAFETY_FIXES[code]}`);
  }

  const assumptions = new Set<string>();
  for (const o of obligations) for (const a of o.assumptions) assumptions.add(a);
  lines.push("", "Scope — the result covers only this:");
  lines.push(
    `  - checked: ${obligations.length} (function, profile) pair(s) the project file or a ` +
      "`// @verify(profile)` comment names — the function and everything it calls, against the " +
      "effects the profile forbids. Nothing else in the sources was checked."
  );
  if (assumptions.size > 0) {
    lines.push(
      (conditional.length > 0
        ? `  - ${conditional.length} obligation(s) are \`conditional\`: they hold IF these declared ` +
          "assumptions do. "
        : "  - the result uses these declared assumptions. ") +
        "kenbi checks a contract against the code wherever the sources contain it; what is " +
        "outside the sources is taken as declared:"
    );
    for (const a of [...assumptions].sort()) lines.push(`      ${a}`);
  }
  lines.push(
    "  - this says what the source MAY do on some path; it does not show that a path runs, and " +
      "it is not the memory-safety check (use `check_memory_safety` for ownership and bounds)."
  );
  return lines.join("\n");
}
