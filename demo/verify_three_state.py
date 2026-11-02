#!/usr/bin/env python3
"""Verify the kenbi three-state Juliet demonstration (demo/juliet*).

For every testcase that exists in demo/juliet/ (the original), demo/juliet_annotated/
(state B) and demo/juliet_rewritten/ (state C), run ./kenbi and check the three-state
property:

    A  original (un-annotated)   -> RED   ("you cannot even write it this way")
    B  honestly annotated        -> RED   ("you cannot annotate your way out")
    C  kenbi-idiomatic rewrite    -> GREEN ("here is how you write it safely")

It ALSO checks the reason-migration property the demo is really about: as you add
the honest intent (state B), the RED reason must converge from a GENERIC boundary
complaint (UNKNOWN_RESOURCE / UNCONTRACTED_ESCAPE …) to the TRUE bug class
(DOUBLE_FREE / USE_AFTER_FREE / LEAK …). A case that stays RED only for a generic
reason in state B is a weakness, not a win, and is flagged.

Usage:  python3 demo/verify_three_state.py [--juliet=PATH]
PATH defaults to $KENBI_JULIET or ../juliet (only its testcasesupport/ is needed for
the #include "std_testcase.h"). Run from the kenbi repo root; build ./kenbi first.
"""
import json, os, re, subprocess, sys

# The per-case converged bug class(es) now live in demo/juliet/manifest.json (the `class` field),
# colocated with each case instead of a hard-coded CWE->class map here. A case's `class` is the
# set of finding codes state B may converge onto (a set for a family like deadlock).
def load_manifest():
    with open(os.path.join(HERE, "juliet", "manifest.json")) as fh:
        return json.load(fh)["entries"]

def driver_files():
    # the three-state unit is the DRIVER; cross-file partners `..._NNb.c` are context only.
    root = os.path.join(ROOT, "demo", "juliet")
    return sorted(f for f in os.listdir(root)
                  if f.endswith((".c", ".cpp"))
                  and not re.search(r"_[0-9]+[b-z](pp)?\.(c|cpp)$", f))

# Generic boundary / hygiene reasons: legitimate RED, but NOT a diagnosis of the bug. For
# spatial, "no bound check at all" (UNVALIDATED_*) is the state-A baseline — a state B that
# stays there has not converged onto kenbi's PRESENT-but-WRONG-check judgment.
GENERIC = {
    "UNKNOWN_RESOURCE", "UNCONTRACTED_ESCAPE", "UNCONTRACTED_RELEASE",
    "UNSTRUCTURED_GOTO", "UNKNOWN_VAR",
    "UNVALIDATED_INDEX", "UNVALIDATED_SIZE",
}
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def support_dir():
    for i, a in enumerate(sys.argv):
        if a.startswith("--juliet="):
            return os.path.join(a.split("=", 1)[1], "testcasesupport")
    j = os.environ.get("KENBI_JULIET", os.path.join(ROOT, "..", "juliet"))
    return os.path.join(j, "testcasesupport")


def run(path, sup):
    out = subprocess.run(["./kenbi", "--format=json", path, "--", "-I", sup],
                         capture_output=True, text=True, cwd=ROOT).stdout
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        return None, None
    errs = [(x["code"], x["line"]) for x in d.get("findings", [])
            if x.get("severity") == "error"]
    return errs, d.get("coverage", {})


def main():
    sup = support_dir()
    dirs = {"A original": "demo/juliet",
            "B annotated": "demo/juliet_annotated",
            "C rewritten": "demo/juliet_rewritten"}
    entries = load_manifest()
    ok = True
    # DRIFT: the manifest and the on-disk driver files must be in exact correspondence — a case
    # that exists but is unlisted (or listed but missing) would slip past the three-state check.
    on_disk = set(driver_files())
    listed = set(e["file"] for e in entries)
    for f in sorted(on_disk - listed):
        print("DRIFT: %s is on disk but missing from manifest.json" % f); ok = False
    for f in sorted(listed - on_disk):
        print("DRIFT: manifest.json lists %s but it is not on disk" % f); ok = False
    # GENERATED: the MCP `explain_finding` data (mcp/src/generated/findings.ts) is generated from
    # this corpus — fail if it is stale, so the served fix-guidance can never drift from the files.
    gen = subprocess.run([sys.executable, os.path.join(HERE, "gen_mcp_from_corpus.py"), "--check"],
                         capture_output=True, text=True)
    if gen.returncode != 0:
        print(gen.stdout.strip() or "generated findings.ts is stale"); ok = False
    for e in sorted(entries, key=lambda e: e["file"]):
        name = e["file"]
        cls = set(e["class"])          # the state-B converged finding code(s) for this case
        print("\n=== %s   (true bug class: %s) ===" % (name, ", ".join(sorted(cls))))
        for state, d in dirs.items():
            p = os.path.join(ROOT, d, name)
            if not os.path.exists(p):
                print("  %-12s : (missing)" % state); ok = False
                continue
            errs, _ = run(p, sup)
            if errs is None:
                print("  %-12s : PARSE-ERROR" % state)
                ok = False
                continue
            codes = sorted({c for c, _ in errs})
            verdict = "RED" if errs else "GREEN"
            tag = ""
            if state.startswith("A") and not errs:
                tag = "  <- expected RED, got GREEN ✗"; ok = False
            if state.startswith("B"):
                if not errs:
                    tag = "  <- annotated your way to GREEN = SOUNDNESS HOLE ✗"; ok = False
                elif cls & set(codes):
                    tag = "  <- reason converged to the true bug class ✓"
                elif all(c in GENERIC for c in codes):
                    tag = "  <- still only a GENERIC reason (NOT converged) ✗"; ok = False
                else:
                    tag = "  <- RED, but not via the expected bug class (review)"
            if state.startswith("C"):
                if errs:
                    tag = "  <- expected GREEN, still RED ✗"; ok = False
                else:
                    tag = "  <- safe, as intended ✓"
            print("  %-12s : %-5s %s%s" % (state, verdict, codes, tag))
    print("\n" + ("ALL THREE-STATE CHECKS PASS" if ok else "SOME CHECKS FAILED — see ✗"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
