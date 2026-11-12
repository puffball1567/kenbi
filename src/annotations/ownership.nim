## Ownership-contract annotations: the declared lifetime/transfer discipline the
## temporal engine enforces. Each is a declarative registration — the generic
## resolver (frontend_c) binds raw sites to functions and the generic consumers
## (lowerCall / fnVisitor / lowerAssign) apply the recorded effect. Adding /
## changing one of these is a single line here; no engine or central-case edit.
##
##   `@frees(p)`   — callsite arg `p` is freed by the callee (ikFree) AND the body
##                   param `p` enters owning a free-once obligation (ikObligation,
##                   CONTRACT_NOT_HONORED if the body never frees it). Dual effect.
##   `@moves(p)`   — callsite arg `p` is moved out (channel/thread handoff): using
##                   it after the call is use-after-move (ikMove).
##   `@adopts(p)` — callsite arg `p` is ADOPTED by the callee: it takes over the release
##                   obligation while the object stays valid (ikAdopt). The container hand-off
##                   (`AppendValueToLinkedList(list, value)`): the collection frees the element
##                   when it is destroyed, but putting it in does not invalidate it. Reading the
##                   value afterwards is fine; releasing it in the caller is a double free; it is
##                   not a leak at exit. `@moves` is the wrong word for this — it declares the
##                   handle dead — and `@frees` is wronger still.
##   `@borrows(p)` — callsite arg `p` is a declared safe borrow (ikUse: used, not
##                   freed / moved / escaped — so it is NOT an UNCONTRACTED_ESCAPE)
##                   AND the body param `p` enters as a borrowed (non-owning)
##                   reference: freeing it is BORROW_FREED; using/returning it is
##                   fine (ikBorrow). Dual effect, like `@frees`.
##   `@owns`        — the call returns a fresh owned object: the result carries a
##                   free-once obligation at the assignment (rcOwned).
##   `@owns(p)` / `@owns(*p)` — the callee allocates INTO its out-parameter (a C++ `T*&`
##                   reference / the pointee of a C `T**`): the callsite's argument variable
##                   becomes an owned origin (declare it with `@mem` there); in the body the
##                   store into the parameter is the declared hand-out, not a leak (ikOwnsOut).
##   `@arena_alloc(a)` — the call returns a region object borrowed from the arena
##                   passed as arg 1: shares its lifetime, never freed individually
##                   (rcArenaFromArg).
##   `@must_use`    — discarding the function's result (a bare statement-call) is a
##                   finding (UNUSED_MUST_USE). A boolean func flag, no param.
##   `@nothrow`     — (C++) the function never throws: a call to it is not an unwinding
##                   exit, so a raw owner held across the call is not LEAK_ON_THROW. The
##                   vouch for a callee whose declaration lacks `noexcept` (a C helper
##                   compiled as C++, a library seam). `@nothrow(name)` vouches a callee
##                   by NAME without binding to a declaration (`@nothrow(operator*)`);
##                   `@nothrow(new)` declares the allocation-failure policy — OOM
##                   terminates, a plain `new` never unwinds (else it is a may-throw point).
##   `@longjmps`    — the function may leave its caller by `longjmp` (directly or through a
##                   callee). A call to it is a possible non-local jump: what the caller still
##                   holds is LEAK_ON_LONGJMP, an object whose destructor the jump skips is
##                   LONGJMP_SKIPS_DESTRUCTOR. Checked against the body: a function that can
##                   reach a longjmp without declaring it is UNDECLARED_LONGJMP. `@longjmps(name)`
##                   and `@contract name { longjmps }` declare a function by NAME — the form for a
##                   library you cannot edit (libpng's `png_error`, …), in an overlay header.

import registry, ../cfront_core, ../ir

proc registerOwnership* =
  registerArgContract("@frees", ikFree)       # callsite: the arg is freed
  registerBodyContract("@frees", ikObligation) # body: the param must be freed here
  registerArgContract("@moves", ikMove)        # callsite: the arg is moved out
  registerArgContract("@adopts", ikAdopt)      # callsite: a consumer takes over the release
  registerArgContract("@borrows", ikUse)       # callsite: a declared safe borrow (no escape)
  registerBodyContract("@borrows", ikBorrow)   # body: the param is borrowed, not owned
  registerReturnContract("@owns", rcOwned)            # return: a fresh owned obligation
  registerArgContract("@owns", ikOwnsOut)             # `@owns(p)` / `@owns(*p)`: allocated INTO the arg
  registerReturnContract("@arena_alloc", rcArenaFromArg) # return: borrows from arg-1 arena
  registerFuncFlag("@must_use")                       # flag: discarding the result is a finding
  registerFuncFlag("@nothrow", "nothrow")             # flag (C++): a call is not an unwinding exit
  registerFuncFlag("@longjmps", "longjmps")           # flag: a call may jump out of the caller
