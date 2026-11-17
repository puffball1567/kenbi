# Changelog

All notable changes to kenbi are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/); before 1.0 the interfaces, the annotation vocabulary
and the JSON output may change in any minor version.

## [0.1.3] - 2026-11-17

### Added

- Landing sites in more forms: `switch (setjmp(b))` (case 0 is the first return, the other cases
  where a jump lands), and an `if` or `switch` on a setjmp at any depth of the function — inside a
  block, a branch, a case or a loop. A jump returns to the latest setjmp on its jmp_buf that ran
  before it, which can be one later in the source when a loop surrounds both; when none is
  certain to have run, the jump may also leave the function and is checked as an exit as well.

### Changed

- `UNSUPPORTED_SETJMP` remains for a setjmp as an expression statement, a loop condition or an
  assignment, or inside a `try` block.

## [0.1.2] - 2026-11-16

### Added

- Landing sites. `if (setjmp(b))` at the top level of a function (also `!setjmp(b)`,
  `setjmp(b) == 0` / `!= 0`) is analysed as the place a longjmp to `b` returns: every later call
  that may jump to `b` is a path into the landing branch, which is checked, with what follows it,
  from all of those paths — a release that does not match on one of them is reported like any
  other. A function's jmp_buf is declared with `@longjmps_to(<expr>)`, or `longjmps: <expr>` in
  `@contract`, where `$N` or a parameter name stands for the call's argument. New codes:
  `UNKNOWN_LONGJMP_TARGET` (a jump after a setjmp whose buffer is not declared),
  `LONGJMP_TARGET_MISMATCH` (a body that jumps somewhere other than it declares),
  `SETJMP_CLOBBERED` (a non-volatile local changed after the setjmp and read where the jump
  lands). In C++, an object declared after the setjmp and in scope at a jump back to it is
  `LONGJMP_SKIPS_DESTRUCTOR`.

### Changed

- `UNSUPPORTED_SETJMP` is now reported only for a setjmp in a form kenbi does not model.

## [0.1.1] - 2026-11-13

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
- A flow whose entry has findings of its own was listed as blocked by "its own `@unsafe`"; it now
  names its own findings unless an `@unsafe` on the entry is the reason.
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

[0.1.3]: https://github.com/puffball1567/kenbi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/puffball1567/kenbi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/puffball1567/kenbi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/puffball1567/kenbi/releases/tag/v0.1.0
