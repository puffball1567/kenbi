// The text summary of a check_memory_safety result. An agent may read only this, so a result
// without findings must carry its scope with it: which checks ran on which functions, what the
// result rests on without having checked it, and what was not analysed at all. "No findings"
// is never phrased as "safe".

import type { KenbiResult, FileScope } from "./kenbi.js";

const AXES: { key: string; label: string }[] = [
  { key: "ownership", label: "ownership, lifetime and null (`@kenbi`, or a file with no marker)" },
  { key: "bounds", label: "bounds (`@spatial`)" },
  { key: "locks", label: "locks (`@threadsafe`)" },
  { key: "initialisation", label: "initialisation (`@initcheck`)" },
  { key: "taggedUnions", label: "tagged unions (`@typecheck`)" },
];

/** At most this many unchecked function names are listed per axis; the JSON has them all. */
const MAX_NAMES = 10;

const base = (path: string) => path.split(/[\\/]/).pop() ?? path;

function axisLine(label: string, key: string, scope: FileScope[]): { line: string; off: boolean } {
  const total = scope.reduce((n, s) => n + s.functions, 0);
  const checked = scope.reduce((n, s) => n + (s.axes[key]?.checked ?? 0), 0);
  const modes = scope.map((s) => s.axes[key]?.mode ?? "off");
  if (modes.every((m) => m === "off")) return { line: label, off: true };
  if (modes.every((m) => m === "file")) return { line: `  - ${label}: checked in every function`, off: false };
  const unchecked: string[] = [];
  for (const s of scope) {
    const a = s.axes[key];
    if (!a || a.mode === "file") continue;
    if (a.mode === "off") unchecked.push(`all of ${base(s.file)}`);
    else for (const n of a.unchecked) unchecked.push(`${base(s.file)}: ${n}`);
  }
  const shown = unchecked.slice(0, MAX_NAMES).join(", ");
  const more = unchecked.length > MAX_NAMES ? `, and ${unchecked.length - MAX_NAMES} more` : "";
  return {
    line: `  - ${label}: checked in ${checked} of ${total} functions; NOT checked in ${shown}${more}`,
    off: false,
  };
}

/** The scope block appended to every summary. */
export function scopeSummary(result: KenbiResult): string {
  const lines: string[] = [];
  const scope = result.scope;
  if (!scope || scope.length === 0) {
    lines.push(
      "Scope: this kenbi did not report which checks ran. Treat the result as covering only the " +
        "checks and functions you opted into."
    );
    return lines.join("\n");
  }
  lines.push("Scope — the result covers only this:");
  const off: string[] = [];
  for (const { key, label } of AXES) {
    const r = axisLine(label, key, scope);
    if (r.off) off.push(r.line);
    else lines.push(r.line);
  }
  if (off.length > 0) lines.push(`  - NOT checked anywhere: ${off.join("; ")}`);
  const blocks = scope.reduce((n, s) => n + s.ownershipBlocks.length, 0);
  if (blocks > 0) {
    lines.push(
      `  - ownership is also checked in ${blocks} \`@kenbi\` block(s) inside functions that are ` +
        "otherwise unchecked; the rest of those functions is not"
    );
  }

  const c = result.coverage;
  if (c) {
    if (c.adopted === 0) {
      lines.push(
        "  - trust: no function is adopted with `@kenbi`, so nothing here is `verified`; calls into " +
          "code that was not analysed rely on its declared contracts"
      );
    } else {
      lines.push(`  - verified (nothing taken on trust): ${c.verified} of ${c.adopted} adopted memory-relevant functions`);
      if (c.trustedFrontier.length > 0) {
        lines.push(
          "  - rests on the contracts of functions whose bodies were not analysed: " +
            c.trustedFrontier.join(", ")
        );
      }
    }
    if (c.unsafeVouches.length > 0) {
      lines.push(
        "  - `@unsafe` (asserted by the author, not checked): " +
          c.unsafeVouches.map((v) => `${v.function} (line ${v.line})`).join(", ")
      );
    }
  }
  lines.push("  - code the preprocessor excluded under these flags was not analysed");
  return lines.join("\n");
}

export function summarize(result: KenbiResult, fileCount: number): string {
  const f = result.findings;
  const errors = f.filter((d) => d.severity === "error").length;
  const warnings = f.filter((d) => d.severity === "warning").length;
  const head =
    f.length === 0
      ? `kenbi: no findings in ${fileCount} file(s) from the checks that ran. This is not a ` +
        "statement about anything outside the scope below."
      : `kenbi: ${errors} error(s), ${warnings} warning(s) across ${fileCount} file(s):\n` +
        f.map((d) => `  ${d.file}:${d.line}: ${d.severity}: ${d.message} [${d.code}]`).join("\n");
  return head + "\n\n" + scopeSummary(result);
}
