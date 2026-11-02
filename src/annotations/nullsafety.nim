## Null-safety decl markers: `@nullable` / `@nonnull` tag a declaration's line so
## the lowering emits the matching null-state instruction. A self-contained
## decl-marker plugin — it writes straight into the generic declMarkers store, so
## the engine consumes it generically (no per-annotation field or case).

import std/tables
import registry, ../cfront_core, ../ir

proc nullable(ctx: var Ctx, a: AnnArgs) = ctx.declMarkers[a.line] = ikNullable
proc nonnull(ctx: var Ctx, a: AnnArgs)  = ctx.declMarkers[a.line] = ikNonNull

proc registerNullSafety* =
  registerCollector("@nullable", nullable)
  registerCollector("@nonnull", nonnull)
