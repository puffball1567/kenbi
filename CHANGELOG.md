# Changelog

All notable changes to kenbi are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/); before 1.0 the interfaces, the annotation vocabulary
and the JSON output may change in any minor version.

## [Unreleased]

### Added

- Non-local jumps. A call to `longjmp` / `siglongjmp` is an exit that runs nothing on the way
  out, and a call to a function declared `@longjmps` a possible one: a raw owner still held there
  is `LEAK_ON_LONGJMP`, and in C++ an object in scope with a non-trivial destructor is
  `LONGJMP_SKIPS_DESTRUCTOR`. A function that can reach a longjmp without declaring `@longjmps` is
  `UNDECLARED_LONGJMP`, so the declaration travels up the call chain; a library function is
  declared by name (`@longjmps(name)`, or `longjmps` in `@contract`). A function that calls
  `setjmp` is reported as `UNSUPPORTED_SETJMP` until landing sites are modelled.

### Fixed

- `longjmp` was treated as a call that returns, so an allocation or a destructor it skipped was
  not reported (0.1.0 passed such code).

- With libclang 17 or later, `--safety` crashed on a project whose `clangArgs` use relative
  include paths, and a function's file could be misidentified: those libclang versions name such
  a file relative to the parse's working directory. File names are now resolved the same way
  with every libclang.

### Changed

- SHA-1 comes from the `checksums` package instead of the deprecated `std/sha1` (a new nimble
  dependency, installed by `nimble build`).
- CI also runs the suites against libclang 15 to 18, and `nimble testall` now includes the
  project coverage suite.
- Issue templates for false positives, bugs and ideas.

## [0.1.0] - 2026-11-11

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

[Unreleased]: https://github.com/puffball1567/kenbi/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/puffball1567/kenbi/releases/tag/v0.1.0
