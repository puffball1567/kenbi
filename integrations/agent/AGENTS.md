# AGENTS.md — kenbi memory safety

This project uses **kenbi**, an annotation-driven static memory-safety checker
for C/C++. The full agent guidance is the canonical
[SKILL.md](./SKILL.md) — read it. This file is a thin wrapper so Codex-style
agents pick the guidance up at the repo root convention.

In short, when you write or review C/C++ that manages memory or acquire/release
resources:

1. **Annotate as you write.** At each allocation declare
   `/* @mem lib::name { size: <expr>, free: <deallocator>, owner: <var> } */`,
   and mark ownership transfers with `// @move lib::name`. Writing the
   annotation forces you to decide who owns and frees the resource.
2. **Run the deterministic checker and trust its verdict.**
   `kenbi --format=json --compile-commands=build/compile_commands.json <file>`.
   Fix every `severity: "error"` finding; re-run after each change
   (propose-then-verify). The tool — not you — decides what is "safe".
3. **Add grounded advisory review** for the residue kenbi can't see (cross-TU
   ownership, valid-until-next-call, custom allocators, dual ownership, secret
   scrub, thread-handoff lifetime, over-broad/unnecessary pointers). Output a
   concrete falsifiable scenario + confidence. Advisory only — never a gate.

**Rule:** you *author* annotations and safer code; the deterministic tool
*judges*. Never emit a "this is safe" verdict on your own authority, and report
a result without findings with the scope kenbi lists for it. Do not repeat in an
ordinary comment what an annotation already declares — the annotation is checked,
the prose copy is not.

See [SKILL.md](./SKILL.md) for the annotation reference, the diagnostic-code
table, and the full residue catalogue.
