<!--
  Copy this to .github/copilot-instructions.md in a repo that uses kenbi.
  Thin grounding for GitHub Copilot; the full guidance is integrations/agent/SKILL.md.
-->
# Copilot instructions — kenbi memory safety (C/C++)

This repository is checked by **kenbi**, an annotation-driven static
memory-safety checker. When you generate or edit C/C++ that manages memory or
acquire/release resources, follow its conventions:

- At each allocation, write an ownership annotation:
  `/* @mem lib::name { size: <expr>, free: <deallocator>, owner: <var> } */`.
  Use scoped resource names (`lib::name`, not bare `name`). The `free:` field is
  the exact deallocator that must release it (any function, not only `free`).
- Mark ownership transfers (into a queue, sink, or another owner) with
  `// @move lib::name`; after a move the variable is moved-from.
- Don't annotate plain values; annotate boundaries (allocation / transfer /
  signatures) and let interior pointers be inferred.
- Prefer the narrowest safe type; avoid an unnecessary pointer when a value or
  stack object would do.
- Don't repeat in an ordinary comment what an annotation already declares (owner,
  deallocator, nullability, guarding lock). The annotation is checked; a prose copy
  is not, and drifts from the code.

The deterministic kenbi checker — not Copilot — decides what is safe. Generate
code and annotations that will *pass* `kenbi`; do not assert safety in comments.

**Advisory findings (severity `advisory`).** kenbi also surfaces intent it does
*not* decide statically — concurrency and locking — for you to review:
`@guarded_by(<lock>)`, `@requires_lock(<lock>)`, `@acquires(<lock>)`,
`@releases(<lock>)`, `@lock_order(<a> < <b>)`, and `@llm <freeform>` for anything
else. These never fail the build; treat each as a directive to verify against the
code (for `GUARDED_BY`, check every access holds the lock; `LOCK_ORDER_CONFLICT`
is a declared deadlock). Report a concrete scenario if violated. Details in
`integrations/agent/SKILL.md` §4.

Full guidance: `integrations/agent/SKILL.md`.
