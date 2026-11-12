# Changelog

All notable changes to kenbi are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/); before 1.0 the interfaces, the annotation vocabulary
and the JSON output may change in any minor version.

## [0.1.0] - 2026-11-12

First version. Checks, each opted into separately:

- **Ownership and lifetime** — use after free, double free, leaks on every exit, use after move,
  wrong deallocator, dangling returns, borrow and arena lifetimes, function contracts checked
  against their bodies, C++ RAII owners, smart pointers, exception paths and deletes through a
  base class without a virtual destructor.
- **Null** — dereference of a possibly-null or known-null pointer (`@nullable` / `@nonnull`).
- **Bounds** (`@spatial`) — an untrusted index or size reaching a buffer needs a present,
  sufficient, overflow-safe bound check; `@counted_by` and declared invariants.
- **Initialisation** (`@initcheck`) and **tagged unions** (`@typecheck`).
- **Locks** (`@threadsafe`) — unguarded access, unbalanced locks, declared lock order.
- **Configured low-level properties** (`--safety=project.json`).

Also: `--project` closure over a `compile_commands.json`, `--emit-contracts`, `kenbi strip`,
`--version`, text and JSON output, and an MCP server (`mcp/`). Every result states its scope:
which checks ran on which functions, and what a result without findings rests on without
having checked it.

[0.1.0]: https://github.com/puffball1567/kenbi/releases/tag/v0.1.0
