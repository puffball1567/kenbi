## Core IR for the kenbi walking-skeleton.
##
## This hand-built IR is a deliberate stand-in for what libclang will later
## produce from real C/C++ source. The analysis engine (analyze.nim) is
## decoupled from the front-end so the parser can be swapped for libclang
## without touching the engine.

import std/[tables, sets, json]

const offsetUnknown* = high(int)
  ## A pointer-offset step, or a running total, that kenbi cannot evaluate — an advance by a
  ## non-constant amount, or two incoming paths that disagree. Carried in `Stmt.off` on an
  ## `ikInterior` step and absorbing into the engine's per-path total, which then never returns
  ## to 0: a later `p -= n` cannot be SHOWN to undo the `p += n` before it, and guessing that it
  ## does would turn a FREE_INTERIOR into a false GREEN.

type
  InstrKind* = enum
    ikAlloc      ## <var> := alloc(<resource>)
    ikCopy       ## <dst> := <src>           (pointer copy / alias to same origin)
    ikRealloc    ## a realloc assignment kenbi cannot model as a plain allocator. Two forms,
                 ## distinguished by whether `bKey` (the source) is present:
                 ##  * SELF-reassign `p = realloc(p, n)` (bKey empty, aKey = the var): on OOM the
                 ##    NULL result overwrites the ONLY handle to the original block, which then
                 ##    leaks irrecoverably. Unconditionally broken -> REALLOC_SELF_REASSIGN
                 ##    (default-red; only `@unsafe` silences it — no reconcile can save it).
                 ##  * FRESH-dest `q = realloc(p, n)` (aKey = dst, bKey = src): the result aliases
                 ##    the source origin (the SUCCESS-path model — "continues the obligation").
                 ##    That model cannot see the failure path (q NULL, original retained via p),
                 ##    and flat analysis cannot verify the reconciliation without the success /
                 ##    null-check correlation across a join. So without a `@realloc` vouch on the
                 ##    line it is REALLOC_UNVERIFIED (default-red); with the vouch kenbi trusts the
                 ##    reconciliation and still verifies the block is freed exactly once.
    ikInterior   ## <dst> := <src> + <off>   (interior pointer into the origin)
    ikLocalAddr  ## <dst> := &<local> / a local array — <dst> points into the
                 ## stack; returning it is a dangling-stack escape (DANGLING_RETURN)
    ikUse        ## read / deref <var>
    ikFree       ## free(<var>)
    ikMove       ## move <var> out (e.g. into a channel)
    ikAdopt      ## a declared consumer ADOPTS <var>: it takes over the release obligation while
                 ## the object stays valid. The container hand-off — `AppendValueToLinkedList(l,
                 ## v)`, `AddValueToSplayTree(t, k, v)`, a registry `Register(x)` — where the
                 ## collection frees the element when it is destroyed, but the element itself is
                 ## not invalidated by being put in. Distinct from `ikMove`, whose whole point is
                 ## that the handle is dead afterwards: reading `v->field` after the append is
                 ## ordinary C, not use-after-move. Distinct from `ikFree`, which would make that
                 ## read a use-after-free. After an adopt the caller may read the object and pass
                 ## it on, but must not release it (that is the consumer's job now) and does not
                 ## leak it at exit.
    ikNullable   ## <var> may be null (from `@nullable`)
    ikNonNull    ## <var> is asserted non-null (from `@nonnull`)
    ikDeref      ## dereference <var> (*p / p->x / p[i]) — null-deref check point
    ikReturn     ## control leaves the function here (divergence). When `a`/`aKey`
                 ## name the returned variable, the engine checks it for escape
                 ## (DANGLING_RETURN) and discharges a returned owned obligation.
    ikObligation ## <var> (a `@frees` param) enters owning an obligation to free it
    ikBorrow     ## <var> (a `@borrows` param) enters as a borrowed (non-owning)
                 ## reference: it must not be freed (BORROW_FREED) and is never a leak
    ikUnsupportedGoto ## a `goto` whose control flow kenbi cannot statically verify even
                 ## with the join-merge model: a *backward* jump (a goto-loop), a jump to a
                 ## label kenbi does not model (nested inside an if/loop), or a *computed* /
                 ## indirect goto with no static target. The front-end emits this instead of
                 ## silently dropping the jump (which would be a soundness hole — a free
                 ## reached only via the jump becomes invisible). In covered scope the engine
                 ## reports UNSTRUCTURED_GOTO (default-red): restructure into structured
                 ## control flow so ownership is trackable. (Sound by refusal.)
    ikBreak      ## `break` — control leaves the innermost loop or switch. In a loop the
                 ## engine routes the current state to the POST-loop join (not the back
                 ## edge), so a `free(p); break;` does not feed the freed state to the next
                 ## iteration (no false cross-iteration double-free). In a switch it routes
                 ## to the post-switch join (a normal case exit).
    ikContinue   ## `continue` — control jumps to the innermost LOOP head (the next
                 ## iteration), skipping the rest of the body. The engine routes the state
                 ## to the loop's back edge (the fixpoint head). A `continue` inside a
                 ## switch targets the enclosing loop, not the switch.
    ikGoto       ## a *forward* `goto <label>` (operand `a` = the target label name) that
                 ## kenbi CAN model: control transfers to a top-level label later in the
                 ## function. The engine deposits the current ownership state into the
                 ## target label's join bucket and ends this straight-line path; the label
                 ## merges every incoming goto state with the fall-through (join-merge), so
                 ## the C cleanup-ladder idiom (`if(!p) goto fail; ... fail: free(...)`) is
                 ## analysed soundly. A goto that is NOT a modelable forward jump is lowered
                 ## as ikUnsupportedGoto instead (the whole function falls back to refusal).
    ikUnaccountedFree ## a deallocator is called on a pointer whose ownership kenbi cannot
                 ## account for: it is not a tracked allocation / @owns result, not a
                 ## contracted parameter — e.g. a local assigned from `*dataPtr` (an
                 ## out-parameter) or from a factory call with no `@owns`. In covered
                 ## scope this is UNCONTRACTED_RELEASE (default-red): declare where the
                 ## pointer comes from (@mem / @owns / @frees / @borrows) or @unsafe.
                 ## Generalises ikIncomingPtr's param case to any untracked release, so a
                 ## free kenbi can't see no longer slips (a soundness hole: an unseen
                 ## free can't be caught as a double-free even once correctly annotated).
    ikIncomingPtr ## <var> is a pointer PARAMETER with NO ownership contract. kenbi does
                 ## not know whether this function owns it, so: using / passing it is
                 ## fine and it is never a leak (the caller owns it), but FREEING it is
                 ## UNCONTRACTED_RELEASE (default-red, the intake-side boundary symmetric
                 ## to ikEscapeCall on the call side) — declare @frees / @borrows / @moves.
    ikArenaAlloc ## <dst> := arena_alloc(<arena>) — dst is owned by the arena <b>:
                 ## it shares the arena's lifetime (use after the arena is destroyed
                 ## = BORROW_OUTLIVES_OWNER), must not be individually freed
                 ## (BORROW_FREED), and is never itself a leak (the arena owns it).
    ikRaiiAlloc  ## <var> is constructed as a local of an `@raii` class (unique_ptr /
                 ## kir_owned_scalar): it OWNS a resource its destructor releases at scope
                 ## exit. Owned origin — `std::move` moves it out (later use = USE_AFTER_MOVE,
                 ## second move = DOUBLE_MOVE) — but never a leak (the dtor frees). `b` = the
                 ## class name (the declared resource). The RAII release is the guarantee
                 ## kenbi trusts, declared by `@raii`, not inferred from the class body.
    ikRaiiMove   ## <b> := std::move(<a>) between owners of the SAME class (`T y = std::move(x)`,
                 ## `y = std::move(x)`, field-wise for a struct of owners): the resource stays
                 ## in view — <b> now holds it (aliased to <a>'s origin, so a borrow taken from
                 ## <a> stays valid and <b>'s destructor releases it) and only the HANDLE <a> is
                 ## moved-from (use = USE_AFTER_MOVE, second move = DOUBLE_MOVE). Contrast
                 ## ikMove, where the resource leaves our view (a `@moves` sink, another class).
    ikMaybeFreedResult ## <var> := f(...) where f's VISIBLE body frees the pointer it returns and
                 ## declares no return contract: the result is a possibly-dangling handle — a
                 ## default-red advisory origin (a use is POSSIBLE_USE_AFTER_FREE, a free
                 ## POSSIBLE_DOUBLE_FREE, never a leak). The result-side sibling of the
                 ## uncontracted `visibly frees its argument` advisory. `b` = the callee.
    ikOwnsOut    ## contract tag for `@owns(p)` / `@owns(*p)`: the callee allocates a fresh owned
                 ## object INTO its out-parameter — a C++ `T*&` reference, or the pointee of a C
                 ## `T**`. At the callsite the argument variable becomes an owned origin (the
                 ## caller owns what it received); in the body the store into that parameter
                 ## is the declared hand-out (an escape, not a leak). Never executed as an
                 ## instruction — the front-end lowers both sides directly.
    ikMayThrow   ## control MAY leave the function here by unwinding: a call to a callee with
                 ## no nothrow guarantee (not `noexcept` / `throw()` / `@nothrow`), or a plain
                 ## `new` (bad_alloc). Every RAW owner still held here — a declared resource or
                 ## a `@frees` obligation; not an RAII owner, whose destructor runs during
                 ## unwinding — is lost on that path: LEAK_ON_THROW. `a` = the callee. Emitted
                 ## for C++ with exceptions on only (never for C or under `-fno-exceptions`).
    ikSetNull    ## <var> is assigned a NULL constant (`p = NULL`, or the result of a release
                 ## declared to return NULL). It owns nothing from here, and RELEASING it is a
                 ## no-op — `free(NULL)` is defined to do nothing in C, and `free(p); p = NULL;`
                 ## is the standard defensive idiom: flagging the next release as a double free
                 ## would accuse correct code. Any later rebinding (an allocation, a copy) ends
                 ## it.
    ikRebind     ## <var> is ASSIGNED something kenbi cannot place — a pointer read out of an
                 ## untracked field (`nxt = cur->next`, the intrusive-list step), the result of
                 ## an uncontracted call, any RHS none of the binding forms above recognised.
                 ## The handle stops naming whatever it named before. Without this the old
                 ## binding SURVIVED the assignment, so the variable kept the identity of a
                 ## resource it no longer points at: the next release read as a DOUBLE_FREE and
                 ## every later dereference as a USE_AFTER_FREE — kenbi accusing correct code of
                 ## the very bug it exists to find (5 such claims on one 30-line linked-list
                 ## prune, 8 in ImageMagick's segment.c). Not silence: the origin it dropped is
                 ## still owed by someone (an orphaned one is a LEAK at exit) and the handle is
                 ## now of unknown provenance, so releasing it is UNCONTRACTED_RELEASE — the
                 ## default-red question "where did this come from?", which a contract answers.
    ikLinkRead   ## <a> := <b>-><link>   — a walk step along the declared `link:` field of a
                 ## resource that is an intrusive collection. <a> becomes a CURSOR on the same
                 ## collection: the same origin, so the walk is not a handle kenbi cannot place
                 ## (ikRebind), and not a second object either. `cKey` carries the field name
                 ## the source wrote, so the engine can check it against what the base's
                 ## resource actually declares — a `next` field on some unrelated struct is a
                 ## plain unplaceable read, exactly as before. Reading the link out of an
                 ## element that was just released is a USE_AFTER_FREE (the classic
                 ## `free(cur); cur = cur->next;`).
    ikListDrain  ## `@drains(<head>)` on a loop: the loop releases EVERY element of the
                 ## collection rooted at <a>. Emitted after the loop. The declaration is
                 ## verified, not trusted: a loop that releases nothing is CONTRACT_NOT_HONORED.
                 ## Once drained the collection is discharged (no leak) and every cursor on it
                 ## dangles (a later use is USE_AFTER_FREE), which is what makes the discipline
                 ## checkable rather than a suppression.
    ikReArm      ## the container yields its NEXT element into <a>'s slot: the slot's EXISTING
                 ## origin is owned again (one distinct object per iteration), so a release
                 ## every iteration is not a double free of one object — and the release does
                 ## discharge the element the container was holding. Emitted at the top of a
                 ## range-for body over a container that holds an owned element.
    ikUnsupportedConstruct ## a statement kenbi does not model whose subtree CONTAINS an
                 ## allocation or a release (a lambda body, a Windows `__try`, a statement
                 ## expression …). Dropping it silently would hide that free / alloc — the
                 ## false-GREEN failure — so the front-end emits this instead and the engine
                 ## refuses the function (UNSUPPORTED_CONSTRUCT). An unknown construct with no
                 ## memory operation in it stays inert. `a` = a short description.
    ikNonVirtualDelete ## `delete <a>` through a pointer to class <b> whose destructor is not
                 ## virtual. off = 1: the object was constructed here as a class derived from <b>
                 ## (undefined behaviour — the derived destructor never runs); off = 0: its dynamic
                 ## type is not in view and <b> is a base of some class, so it cannot be shown to be
                 ## a <b> (default-red).
    ikThrow      ## `throw e;` — control leaves by unwinding: inside a `try` it lands in the
                 ## handlers (deposited on the frame), else it is a function exit that carries
                 ## nothing (every raw owner still held leaks).
    ikMustUse    ## the result of a `@must_use` call at <a> is discarded (statement-expr)
    ikEscape     ## <var> is stored into an untracked location (a struct field /
                 ## `*p` / `arr[i]`): the obligation leaves our view, so it is not a
                 ## leak. Conservative: we stop tracking it (field ownership = #2).
    ikFieldAlloc ## <field-path> := alloc(...)  — a pointer stored directly into a
                 ## one-level field path (`b->buf = malloc()`). Tracked for
                 ## double-free / use-after-free THROUGH the field; never leak-scanned
                 ## (the base may escape, carrying the field's obligation with it).
    ikFieldStore ## <field-path> := <tracked owned var>  (`b->buf = p`) — an existing owned
                 ## pointer stored into a one-level field path. The field takes ownership: the
                 ## origin is re-keyed to the field and tracked for double-free / use-after-free
                 ## through it (like ikFieldAlloc), and excluded from the leak scan (the base may
                 ## escape carrying the obligation — full field lifetime is the deferred #2 work).
    ikFieldBaseEscape ## <base-var> escapes whole (`return b` of a struct that owns fields): the
                 ## container transfers, carrying its fields' obligations with it, so those fields
                 ## do not leak at scope exit. Discharges a self-evident whole-struct transfer; an
                 ## UNrecognised container escape stays default-red (its owned field leaks — declare
                 ## the transfer). `aKey` = the base var key.
    ikEscapeCallFrees ## like ikEscapeCall, but kenbi can SEE the callee's body
                 ## frees this argument (no @frees contract is declared, though).
                 ## Still UNCONTRACTED_ESCAPE (default-red — declare @frees), and the
                 ## engine additionally marks the pointer "maybe-freed" so a later
                 ## free / use is a POSSIBLE_DOUBLE_FREE / POSSIBLE_USE_AFTER_FREE
                 ## *advisory* (a hint, never an assertion — confirmation comes once
                 ## @frees is written, which makes it a confident DOUBLE_FREE).
    ikEscapeCall ## <var> is passed as an argument to an *uncontracted* callee <b>
                 ## (no @frees / @borrows / @moves contract, not a known-safe libc
                 ## borrow). kenbi cannot verify whether the callee frees / borrows /
                 ## stores it, so it must NOT silently infer a borrow (that would
                 ## bless a hidden free = a false-negative double-free). The engine
                 ## decides by ownership: an owned arg here is UNCONTRACTED_ESCAPE
                 ## (default-red, the cross-function discipline boundary). Behaves
                 ## like ikUse for the use-after-free / -move / arena checks too.
    ikIndex      ## SPATIAL sink: a value <a> is used to index / size a dangerous
                 ## operation (`arr[a]`, `memcpy(.., a)`). `off` = the destination buffer's
                 ## size if a fixed array (<0 = unknown); `bKey` = the buffer's symbolic
                 ## allocation-count identifier if it was `malloc(n)`/`calloc(n,..)` ("" = none),
                 ## so an `idx < n` bound naming the same identifier covers it. In spatial-covered scope the
                 ## spatial pass requires <a> to be VALIDATED (a runtime bound check is
                 ## present on the path: an if-guard / loop-cond / `%` / clamp / mask /
                 ## marked validator); an unvalidated value here is UNVALIDATED_INDEX
                 ## (default-red). kenbi confirms a check EXISTS — it never proves a
                 ## check unnecessary in order to remove it; what it establishes is that
                 ## the check physically exists.
    ikValidate   ## SPATIAL: value <a> becomes VALIDATED here (a bound check produced it:
                 ## `x % n`, a clamp/mask, a loop/if bound, or a @validates contract).
                 ## CONSTANT bound: `bKey` empty, `off` = the strict upper bound (value < off).
                 ## SYMBOLIC bound: `bKey` = the bound identifier's key (`value` is bounded by
                 ## that variable), `b` = its display name, `off` = the offset (`value < sym +
                 ## off`; 0 = `value < sym`, 1 = `value <= sym`). Covers a `malloc(sym)` buffer
                 ## by identity.
    ikTaint      ## SPATIAL: scalar value <a> becomes UNVALIDATED here — assigned from an
                 ## untrusted / unknown source (a parameter, a call return, a pointer
                 ## deref / field read, or non-bounding arithmetic). Must be re-validated
                 ## before a sink. Clears any prior validation (avoids a false negative
                 ## when a once-validated var is reassigned to untrusted data).
    ikLowBound   ## SPATIAL (lower bound): scalar value <a> is known `>= off` on the path —
                 ## from a constant initializer (`i = 0`) or, inserted by the loop lowering,
                 ## a `>= 0` loop condition. Index sinks require a SIGNED index to have a
                 ## lower bound covering the access (`i + k >= 0`); an unsigned index gets
                 ## `>= 0` from its type. Without one, a signed index could be negative
                 ## (out of bounds below) — INDEX_MAYBE_NEGATIVE (default-red). `aKey`/`a` =
                 ## the value; `off` = the known lower limit.
    ikValueCopy  ## SPATIAL: scalar <a> := <b> — <a> inherits <b>'s validated-state (so a
                 ## copy of a checked value stays checked, and a copy of a tainted value
                 ## stays tainted). Distinct from ikCopy, which is pointer-origin aliasing.
    ikMaintainsCheck ## INVARIANT: a write to a protected field that IS `@maintains`-
                 ## annotated. The spatial pass VERIFIES the claim — that this write
                 ## preserves the declared relation `field REL size`. For an increment by
                 ## `off` (δ), preservation needs `field <= size - δ` BEFORE the write (the
                 ## guard establishes it); a decrement / no-op preserves an upper bound
                 ## unconditionally. A write that cannot be shown to preserve it is
                 ## INVARIANT_NOT_MAINTAINED (the @maintains claim is a lie — the
                 ## conformance check). `a`/`aKey` = field, `b`/`bKey` = the
                 ## size operand, `off` = the write's delta, `off2` = the relation
                 ## (0 = `<`, 1 = `<=`). Verified preservation is what later lets the
                 ## invariant green an access (slice 5).
    ikInvariantWrite ## INVARIANT: a write (`=`, `+=`, `++`/`--`) to a field/var declared
                 ## PROTECTED by an `@invariant`, on a line NOT carrying `@maintains`. In
                 ## covered scope this is UNGUARDED_INVARIANT_WRITE (default-red): every
                 ## write to a protected field must declare its effect (so a write that
                 ## could break the invariant cannot slip past — the write-barrier that
                 ## makes the invariant trustworthy). `a`/`aKey` name the field. The
                 ## front-end emits it only for an unannotated write to a protected field;
                 ## a `@maintains` write emits nothing (its preservation is checked
                 ## separately).
    ikEstablishCheck ## INVARIANT (slice 4 — init/establish): a SET write `field = rhs`
                 ## that IS `@maintains`-annotated. Unlike ikMaintainsCheck (an increment,
                 ## whose preservation depends on a prior guard), a set ESTABLISHES the
                 ## relation directly from its RHS — it is the induction base case (the
                 ## init leg). The spatial pass VERIFIES `rhs REL size` by a fixed
                 ## vocabulary: `rhs` a pure constant (`field = 0` keeps `field <= size`
                 ## iff size is unsigned, so `0 <= size`), or `rhs = size ± k` (keeps
                 ## `field <= size` iff k <= 0). An unverifiable RHS is
                 ## INVARIANT_NOT_MAINTAINED (declare-don't-infer: never assumed). `a`/`aKey`
                 ## = field, `b`/`bKey` = size operand, `cKey` = the RHS term's key (""=a
                 ## pure constant, "@opaque"=RHS kenbi cannot read as a linear form),
                 ## `off` = the RHS constant offset (`rhs = cKey + off`), `off2` packs the
                 ## relation in bit0 (0=`<`, 1=`<=`) and size-is-unsigned in bit1.
    ikLowInvariantCheck ## INVARIANT (C2 — the LOWER bound, symmetric to ikMaintainsCheck /
                 ## ikEstablishCheck): a write to a field declared under a LOWER invariant
                 ## `@invariant(field >= c)` that IS `@maintains`-annotated. The spatial pass
                 ## VERIFIES the write preserves `field >= c` (`c` looked up per-function by
                 ## field key). `a`/`aKey` = the field. `off2` bit0 = isSet (a `field = rhs`
                 ## set vs an `++`/`--`/`+=` delta); bit1 = the RHS term names an UNSIGNED
                 ## value (so it is `>= 0`). For a SET: `cKey` = the RHS linear term's key
                 ## (""=pure constant, "@opaque"=unreadable), `off` = the RHS constant offset
                 ## (`rhs = cKey + off`); preserved iff the value's known lower bound (the RHS
                 ## constant, or an unsigned term's `>= 0`, or a path-tracked `low[cKey]`) is
                 ## `>= c`. For a delta: `off` = δ; a non-negative δ preserves a lower bound,
                 ## a decrement cannot be shown to (RED). An unverifiable write is
                 ## INVARIANT_NOT_MAINTAINED (declare-don't-infer).

    ikLockAcquire ## CONCURRENCY: a lock becomes HELD here — a recognised acquire
                 ## (`pthread_mutex_lock(&m)` / spin / a declared `@acquires`). `aKey`/`a` =
                 ## the lock's identity key / display (the arg expression: `&s->lock` -> the
                 ## `s->lock` field-path key, `&g` -> the var key). The concurrency pass adds it
                 ## to the flow-sensitive held-set. No-op for the temporal / spatial passes.
                 ## v3 stage 3: for a FIELD-instance lock, `b` = its `@lock_class` name and `bKey` =
                 ## the base variable's USR — so the lock-balance pass can detect two distinct
                 ## instances of the SAME class held at once and require a canonical address order.
                 ## (Empty for class-keyed globals / pointer aliases, which collide by key already.)
    ikLockRelease ## CONCURRENCY: a lock becomes NOT-HELD here — a recognised release
                 ## (`pthread_mutex_unlock(&m)` / a declared `@releases`). Removes `aKey` from
                 ## the held-set. No-op for the temporal / spatial passes.
    ikInitWrite  ## INIT (definite-assignment): the local `aKey` becomes DEFINITELY ASSIGNED
                 ## here — a plain `v = …`,
                 ## a compound `v += …` (after its read), `v++`, or `&v` (address taken; a
                 ## callee may initialise it, so kenbi assumes assigned — conservative toward
                 ## no false positive). Adds it to the assigned-set.
    ikVariantAccess ## TYPE-CONFUSION sink: a read/write of a tagged-union member declared
                 ## `@variant(member : tag == value)` — `aKey`/`a` = the member, `bKey`/`b` = the
                 ## discriminant (tag) field, `off` = the value the tag must equal for this member
                 ## to be the active variant. In typecheck-covered scope the pass requires the tag
                 ## to be PROVEN `== value` on the path (an `if (tag == value)` guard); accessing a
                 ## variant whose tag was not checked is TYPE_CONFUSION (default-red — reading the
                 ## wrong union member). The C analogue of a Rust enum's checked discriminant.
    ikInitRead   ## INIT sink: a READ of the local `aKey` (declared without an initializer).
                 ## In init-covered scope the pass requires it to be in the assigned-set on
                 ## every path reaching here; a read of a not-definitely-assigned local is
                 ## USE_OF_UNINITIALIZED (default-red — an indeterminate value / wild pointer).
    ikGuardedAccess ## CONCURRENCY sink: a read/write of a field declared
                 ## `@guarded_by(field: lock)` — `aKey`/`a` = the accessed field, `bKey`/`b` =
                 ## the lock that must be HELD. In thread-safe-covered scope the concurrency
                 ## pass requires `bKey` to be in the held-set on this path; an access without
                 ## the lock held is UNGUARDED_ACCESS (default-red — a data race). kenbi confirms
                 ## a lock is demonstrably held, never that one is unnecessary. No-op elsewhere.
    ikRequiredLockCall ## CONCURRENCY sink: a call to a callee declared `@requires_lock(m)` —
                 ## `a` = the callee name (for the message), `b` = the required lock's display.
                 ## The lock-balance pass requires `b` to be held (by display) on EVERY path to
                 ## the call; a call without it held is REQUIRED_LOCK_NOT_HELD (default-red — the
                 ## callee touches data the caller must have locked). A cross-function lock
                 ## precondition, the held-state analogue of `@frees`. No-op for other passes.
    ikIndirectCall ## CONCURRENCY sink (v3 stage 4): a call THROUGH a function pointer. `a` = the
                 ## pointer's display (for messages); `aKey` = "T" if the pointer has a declared
                 ## `@calls(...)` target set, "" if not; `b` = the ";"-joined lock DISPLAYS the
                 ## declared targets are `@acquires`-declared to take (for the order check). In a
                 ## `@threadsafe` scope the lock-balance pass gates it: NO declared targets while a
                 ## lock is held is UNDECLARED_INDIRECT_CALL (default-red — the callee's lock
                 ## behaviour is unverifiable, so a deadlock cannot be ruled out; resolve by declaring
                 ## `@calls`, NOT by `@unsafe`); with targets, acquiring one of their locks in the
                 ## reverse of a declared `@lock_order` is LOCK_ORDER_VIOLATION (AB-BA via the
                 ## callback). No-op for the other passes.
    ikFnAssign   ## CONCURRENCY sink (v3 stage 4): an assignment `fp = f` / `fp = &f` where `fp` has
                 ## a declared `@calls(...)` set and `f` is NOT in it — the front-end emits this ONLY
                 ## on a violation (the annotation-vs-implementation check, computed with the target
                 ## set in scope). `a` = the pointer's display, `b` = the offending function name. In
                 ## a `@threadsafe` scope this is UNDECLARED_FN_TARGET (default-red): the pointer may
                 ## call a function outside its declared set, so an indirect call through it cannot be
                 ## resolved. Add `f` to `@calls` or don't assign it. No-op for the other passes.
    ikGuardedEscape ## CONCURRENCY sink: the ADDRESS of a `@guarded_by` field is taken (`&c->data`),
                 ## so a pointer to the guarded data escapes the lock's reach — accesses through it
                 ## cannot be verified against the held-set (an alias can race after the lock is
                 ## dropped). `aKey`/`a` = the field. In a thread-safe scope this is GUARDED_ESCAPE
                 ## (default-red, unconditional — held or not): keep the access inline under the lock,
                 ## or declare a contract. The sound analogue of UNCONTRACTED_ESCAPE. No-op elsewhere.

  StmtKind* = enum stInstr, stIf, stLoop, stSwitch, stLabel, stTry

  Stmt* = ref object
    line*: int
    case kind*: StmtKind
    of stInstr:
      ik*: InstrKind
      a*, b*: string       ## operands: variable *display* names / resource name
      aKey*, bKey*: string ## stable identity keys for a/b (e.g. clang USR).
                           ## Empty => identity is the display name (mini-format).
      cKey*: string        ## a THIRD operand key, used by ikEstablishCheck for the
                           ## RHS term of a SET-form `@maintains` write (""=pure
                           ## constant, "@opaque"=unreadable RHS, else a variable/field
                           ## key compared against bKey to see if `rhs = size ± off`).
      off*: int            ## interior offset
      off2*: int           ## SPATIAL (ikIndex): the index/length expression's constant
                           ## offset from the tracked value — `buf[i + k]` carries k, so
                           ## the bound on `i` must cover `i + k` (need `i < size - k`).
      off3*: int           ## SPATIAL (ikIndex, SYMBOLIC buffer only): the buffer's size
                           ## offset — it holds `bKey + off3` elements (a declared
                           ## `@counted_by(buf: mask + 1)` gives off3 = 1, the power-of-two
                           ## ring-buffer idiom). The covering check needs `effOff + j <=
                           ## needOff + off3`. 0 for a plain `malloc(n)` buffer.
    of stIf:
      thenBody*: seq[Stmt]
      elseBody*: seq[Stmt]
      condKey*: string     ## if the condition is a null-test of a var: its key ("" = none)
      condDisp*: string    ## display name of that var
      condThenNonNull*: bool ## true: the THEN branch implies the var is non-null
      nonNullThen*, nonNullElse*: seq[tuple[key, disp: string]]
                             ## every pointer a COMPOUND condition proves non-null on that
                             ## branch: `if (a != NULL && b != NULL)` proves both on THEN,
                             ## `if (a == NULL || b == NULL) return;` proves both on the
                             ## fall-through. The single-test `condKey` above carries the
                             ## null side too (it discharges an owned-but-null pointer); a
                             ## compound condition cannot say WHICH operand is null, so only
                             ## the non-null facts are recorded — knowledge that only ever
                             ## adds checking. C guards the allocation of several buffers in
                             ## exactly this shape, and without it every later use of them
                             ## was a possibly-null dereference.
      tagFacts*: seq[tuple[key: string, value: int, onThen: bool]] ## TYPE-CONFUSION: each
                             ## `tag == value` equality the condition proves, per branch (a guard
                             ## `if (n->tag == 0)` proves `(n->tag, 0)` on its THEN branch). The
                             ## type-confusion pass uses these to know a variant member is safe.
      condBounds*: seq[BoundEffect] ## SPATIAL: every relational bound the condition places
                             ## on a value, per branch. A compound `&&` contributes one
                             ## effect per conjunct (`if (i >= 0 && i < n)`); a single
                             ## relational contributes the THEN bound and the negated ELSE
                             ## bound (so `if (x >= N) return;` validates the fall-through).
      predKey*: string       ## CORRELATED BRANCHES: the STABLE scalar this condition tests —
                             ## a local or parameter the function never assigns and never takes
                             ## the address of, so its value cannot change between two tests of
                             ## it. Empty when the condition is anything else (a call, a mutable
                             ## variable, a field a callee could change), which is most of them.
      predThenNonZero*: bool ## true: the THEN branch is the one where `predKey` is non-zero
                             ## (`if (x)`); false: THEN is where it is zero (`if (!x)`).
      condLockKey*: string   ## CONCURRENCY: a `trylock` whose SUCCESS branch holds this lock
                             ## (its identity key). "" = none. trylock returns 0 (success, lock
                             ## HELD) or nonzero (failure) — so it is a CONDITIONAL acquire,
                             ## recognised here via the `if` condition rather than as an
                             ## unconditional ikLockAcquire. The concurrency / lock-balance passes
                             ## add it to the held-set of the SUCCESS branch only.
      condLockDisp*: string  ## display name of that lock (for messages)
      condLockOnThen*: bool  ## true: success (lock HELD) is the THEN branch (`trylock()==0` /
                             ## `!trylock()`); false: success is the ELSE / fall-through
                             ## (`trylock()!=0`, or bare `if(trylock())` — nonzero = failure).
      condPtrL*, condPtrR*: string ## CONCURRENCY (v3 stage 3, same-class order): the USRs of the two
                             ## pointer variables compared in the condition (`if (a < b)`); "" = no
                             ## pointer comparison. Establishes a canonical address ordering per branch
                             ## so that locking two same-class instances in that order is legal.
      condPtrOp*: string     ## the comparison operator relating L and R ("<", ">", "<=", ">="). On the
                             ## THEN branch it holds as written; on the ELSE branch its negation holds
                             ## (for DISTINCT instances `!(a<b)` ⇒ `b<a`).
    of stTry:
      tryBody*: seq[Stmt]       ## `try { ... }`: every unwinding exit inside it (a throw, a
                                ## may-throw call) lands in the handlers, not the function exit
      handlers*: seq[seq[Stmt]] ## one body per `catch` clause — alternatives entered from the
                                ## JOIN of those unwinding exits
      handlerTypes*: seq[string] ## per handler: the caught type, canonical and stripped of
                                ## const / reference (`catch (const T&)` -> `T`), or "..." for
                                ## `catch (...)`. A deposit from a literal `throw e` carries e's
                                ## type and is consumed by the first handler naming EXACTLY it;
                                ## a deposit from a may-throw call carries none and reaches every
                                ## handler; whatever no handler consumes propagates
    of stLoop:
      loopBody*: seq[Stmt] ## a for/while/do body (the init/cond/inc are lowered
                           ## around it). Analyzed for in-body effects; cross-
                           ## iteration ownership is a discipline concern (@arena).
      doWhile*: bool       ## the body runs AT LEAST ONCE (a do-while, a `while (1)` / `for (;;)`,
                           ## or a restructured `@goto_backward` goto-loop): the loop exits only
                           ## via a break (the cond-false-after-iteration), never a 0-trip head,
                           ## so the post-loop state excludes the entry — avoids a false 0-trip leak.
      contExits*: bool     ## a `continue` in this body jumps to a test that MAY be false, so it
                           ## is an EXIT edge as well as a back edge. True for a bottom-tested
                           ## `do … while (cond)`; false when the controlling test is a non-zero
                           ## constant (`while (1)`), where `continue` always re-enters the body.
                           ## Only consulted when `doWhile` is set — otherwise the loop exits at
                           ## the head, which already joins every continue.
      noBackEdge*: bool    ## the body runs AT MOST ONCE: `do … while (0)`, the standard C
                           ## multi-statement macro wrapper. There is no second iteration, so no
                           ## fixpoint over the back edge — without this the release in a
                           ## `do { … free(p); } while (0)` read as a double free of itself.
    of stSwitch:
      cases*: seq[seq[Stmt]] ## one body per case group; analyzed as independent
                             ## branches from the switch entry (may-set merged,
                             ## plus the entry state for the no-match path).
      hasDefault*: bool      ## a `default:` label exists — then there is no
                             ## no-match fall-through path.
      switchKey*: string     ## TYPE-CONFUSION: the discriminant the switch is on, if it is a
                             ## member-ref field (`switch (n->tag)` -> the `n->tag` key); "" else.
      switchDisp*: string    ## display name of the discriminant
      switchPredKey*: string ## CORRELATED BRANCHES: the STABLE scalar this switch is on (see
                             ## `predKey` on stIf). Separate from `switchKey`, which the
                             ## type-confusion pass owns and which only ever names a discriminant
                             ## FIELD: widening that one would change what that pass sees.
      caseValues*: seq[int]  ## TYPE-CONFUSION: parallel to `cases` — the single constant value a
                             ## case group's label proves (`case 0:` -> 0), so `n->tag == 0` is
                             ## known in that body. low(int) for default / multi-label (fall-through)
                             ## / non-const groups (no single proven value).
    of stLabel:
      labelName*: string     ## a `goto` target. A JOIN point: the engine merges the
                             ## fall-through state with every ikGoto state targeting it
                             ## (join-merge). Only top-level labels are modelled; a label
                             ## nested in an if/loop makes the function fall back to refusal.

  BoundEffect* = object
    ## SPATIAL: one bound a condition places on a value. By default an UPPER bound
    ## normalised to the strict form `value < limit` — CONSTANT (`value < constLimit`) or
    ## SYMBOLIC (`value < symKey + symOff`, an identity bound naming a buffer's allocation
    ## count — `symOff` folds strictness and any `±k`). When `isLower`, it is instead a
    ## CONSTANT LOWER bound `value >= constLimit` (`i >= 0` from a guard / loop condition /
    ## negated `i < 0`), used to discharge the signed-index lower-bound requirement.
    ## When `isNeq`, it is instead a DISEQUALITY `value != constLimit` (`if (x != -1)`): it
    ## RAISES a known lower bound of exactly `constLimit` to `constLimit + 1` on its branch
    ## (a `!= c` only improves the lower bound when the value is already known `>= c`, e.g. a
    ## declared `@invariant(field >= -1)`). It asserts no bound on its own — sound.
    ## Applied to the THEN branch when `onThen`, else the ELSE branch.
    key*: string        ## the bounded value's key
    onThen*: bool       ## true: holds on the THEN branch; false: on the ELSE branch
    isLower*: bool      ## true: a LOWER bound `value >= constLimit`; false: an upper bound
    isNeq*: bool        ## true: a DISEQUALITY `value != constLimit` (lifts a known `>= c`)
    isConst*: bool      ## a constant bound (constLimit) vs a symbolic one (symKey + symOff)
    constLimit*: int    ## value < constLimit (upper) / value >= constLimit (when isLower)
    symKey*: string     ## value < symKey + symOff      (when not isConst)
    symDisp*: string    ## display name of the bound identifier
    symOff*: int        ## the offset added to the symbol in the normalised bound
    # OVERFLOW-SAFETY (spatial soundness). A guard whose arithmetic can WRAP at runtime is
    # credited in ℤ but is not sound under wraparound; these carry that hazard to the sink,
    # which drops coverage for the accesses the wrap actually exposes (see analyze.nim).
    wrapVar*: bool      ## the UNTRUSTED-variable side carried a positive offset `var + gk`:
                        ## `var + gk` can misbehave near the type extreme, so the ℤ bound is
                        ## unsound. UNSIGNED: `var + gk` wraps to a small value that the check
                        ## catches, so the bound is still sound for an access at EXACTLY `gk`
                        ## (only `j < gk` is exposed). Sink refuses when `j < wrapGuardOff`.
    wrapGuardOff*: int  ## `gk` — the positive offset on the variable side (when wrapVar)
    wrapVarStrict*: bool ## the variable side is SIGNED (option B): `var + gk` overflow is UB,
                        ## and for `var` near INT_MAX it wraps to INT_MIN — a large NEGATIVE
                        ## that passes `< limit` yet indexes far out of range. Unlike the
                        ## unsigned wrap (which lands at 0, in range) there is NO safe access
                        ## offset, so the sink refuses EVERY access (`j <= wrapGuardOff`),
                        ## including the `j == gk` neighbour form. Whether `var + gk` overflows
                        ## is an unverified property of an untrusted value — default-red.
    wrapLimNeed*: int   ## the LIMIT side carried a negative offset `sym - k` (unsigned sym):
                        ## `sym - k` UNDERFLOWS to a huge value when `sym < k`, making the
                        ## bound vacuous. Sink requires the companion `sym >= wrapLimNeed`
                        ## (a tracked lower bound) on the path; 0 = no limit-side hazard.
    needsLtCompanion*: bool ## the overflow-SAFE two-variable idiom `sym - key >= k` (the
                        ## parser "remaining bytes" check): bounds `key` by `sym` with headroom
                        ## `k`, keeping the arithmetic off the untrusted `key`. But `sym - key`
                        ## UNDERFLOWS when `key > sym` (unsigned), so it is creditable only when
                        ## a sibling conjunct establishes `key <= sym` (`p < end`). Resolved in
                        ## the frontend (reconcileHeadroom) — cleared when a companion is found,
                        ## the whole bound dropped otherwise; never reaches the analyzer set.

  Resource* = object
    ## A declared logical resource (registry entry). The scoped, project-unique
    ## name (e.g. "lib::image") keys the registry; size/free/owner bind to it.
    name*: string
    sizeId*: string
    freeId*: string      ## the resource's PRIMARY release, named in messages
    freeIds*: seq[string] ## every release the resource accepts. A family legitimately has
                         ## several entry points — one allocator with typed destroy wrappers
                         ## around it (ImageMagick allocates a KernelInfo with
                         ## `AcquireQuantumMemory` and releases it with `DestroyKernelInfo`,
                         ## whose own body calls `RelinquishMagickMemory`) — and declaring them
                         ## all is what keeps WRONG_DEALLOCATOR a real check instead of a
                         ## complaint about the second name on the list.
    allocIds*: seq[string]  ## the entry points that PRODUCE this resource (`@allocator`'s
                         ## `alloc:` / `@arena`'s `create:`). Empty for a per-site `@mem`,
                         ## which hangs on one allocation rather than naming a family. Kept
                         ## so the alloc -> free pairing can be PUBLISHED (`--emit-contracts`):
                         ## a consumer that only learns the deallocators cannot tell which
                         ## call handed it the obligation.
    reallocIds*: seq[string] ## the family's resize entry points (`realloc:`)
    nullingFreeIds*: seq[string] ## the subset of `freeIds` declared `free_returns_null:` —
                         ## releases that hand back NULL, so `p = release(p)` leaves p owning
                         ## nothing instead of reading as a double free
    ownerId*: string
    linkId*: string      ## `link: <field>` — this resource is a NODE of an intrusive
                         ## collection whose elements are chained through that field
                         ## (`cur->next`). Declaring it is what lets kenbi read a walk
                         ## (`cur = cur->next`) as another element of the same collection
                         ## instead of an object it cannot place, and what makes a release
                         ## in the walk an ELEMENT removal rather than a release of "the"
                         ## resource. Empty = an ordinary single-object resource.
    declLine*: int

  CallKind* = enum
    ## How a call participates in the *ownership* flow (only calls that pass a
    ## tracked owned/borrowed pointer are recorded — the adoption unit is a flow).
    ckKnown        ## a libc deallocator / known-safe borrow (free / printf / …):
                   ## an ownership op, but not a user function to cover (flow leaf)
    ckContracted   ## a user callee with a declared @frees / @moves / @borrows
                   ## contract — the caller trusts that contract (modular trust).
                   ## If the callee's body is not itself covered, it is the
                   ## *trusted frontier*: GREEN here rests on an unverified body.
    ckUncontracted ## an uncontracted boundary (UNCONTRACTED_ESCAPE): the caller
                   ## cannot be GREEN until a contract / region / @unsafe resolves it

  CallEdge* = object
    callee*: string  ## the called function's name (a user function or a known libc op)
    line*: int       ## the call site line
    kind*: CallKind

  Func* = object
    ## One C/C++ function: its lowered body plus its declared signature contract.
    name*: string
    file*: string                ## the translation unit it was defined in (project coverage)
    isStatic*: bool              ## `static` / anonymous-namespace linkage: invisible to other
                                 ## TUs, so a project merge must key it per file, never by name
    body*: seq[Stmt]
    freesParams*: seq[tuple[key, disp: string]] ## params declared `@frees` (must free them)
    ownsReturn*: bool            ## `@owns`: the return value carries an obligation
    mustUse*: bool               ## `@must_use`: discarding the return is a finding
    line*: int                   ## declaration line (for contract diagnostics)
    calls*: seq[CallEdge]        ## ownership-relevant call edges (for per-flow coverage
                                 ## + trusted-frontier)
    invariants*: seq[tuple[fieldKey, sizeKey, sizeDisp: string, symOff: int]]
                                 ## INVARIANT (slice 5+): the declared `@invariant`s in scope
                                 ## for this function — a PROTECTED field key, the size operand
                                 ## it is bounded by (key + display), and `symOff` folding the
                                 ## relation to a strict upper bound (`field < sizeKey + symOff`:
                                 ## 1 for `<=`, 0 for `<`). The spatial pass CHAINS through these
                                 ## at an index sink: `i < field` ∧ `field < size` ⟹ `i < size`,
                                 ## greening `buf[i]` when `buf` is `@counted_by(size)`. The
                                 ## invariant is trusted here because slices 2-4 made every write
                                 ## to the field guarded/established (or RED).
    lowInvariants*: seq[tuple[fieldKey: string, lowConst: int]]
                                 ## INVARIANT (C2): the declared LOWER invariants in scope —
                                 ## a PROTECTED field key known `>= lowConst` (`toksuper >= -1`).
                                 ## At an index sink the field's known lower bound includes this
                                 ## (function-wide, like the upper invariant), discharging the
                                 ## signed-index lower-bound requirement once a `!= c` / `>= 0`
                                 ## guard lifts it. Trustworthy via the same write-barrier:
                                 ## every write preserves it (ikLowInvariantCheck) or is RED.
    copyGaps*: seq[tuple[cls, what: string, line: int]]
                                 ## RULE OF THREE: every place in this function that COPIES an
                                 ## `@raii` class which has no such copy operation of its own. The
                                 ## compiler's implicit member-wise copy hands the two objects the
                                 ## same pointer, and both destructors release it. Recorded at the
                                 ## copy rather than on the class, because a class that can be
                                 ## copied wrongly but never is has no double free.
    selfAssignCls*: string       ## SELF-ASSIGNMENT: on an `@raii` class's `operator=` that
                                 ## releases a member and afterwards reads the source, with no
                                 ## guard comparing the source against `this` — the class name.
                                 ## `x = x` is legal C++, and on that path the read is of memory
                                 ## the operator just freed. Empty when the operator is safe
                                 ## (guarded, or reading before releasing).
    acquiresLocks*: seq[tuple[key, disp: string]]
                                 ## CONCURRENCY (lock-balance): locks this function is declared to
                                 ## leave HELD at every exit (`@acquires`) — an intentional hand-off
                                 ## to the caller, NOT a leak. Verified: a lock so declared must be
                                 ## provably held on every exit path (else LOCK_NOT_ACQUIRED).
    releasesLocks*: seq[tuple[key, disp: string]]
                                 ## CONCURRENCY (lock-balance): locks the caller's contract holds at
                                 ## ENTRY (`@releases`) — seeded into the held-set; the function must
                                 ## release each before it returns (a still-held one is LOCK_LEAKED).

  ContractPackage* = object
    ## `@contracts_for <library> { version: …, requires: NAME=VALUE … }` — the identity of a
    ## set of contracts shipped for a library, and the build conditions they were written
    ## against. A contract overlay is useless to a consumer without this: contracts describe a
    ## particular version built a particular way, and "these contracts apply here" is a claim
    ## like any other — declared, then checked as far as it can be.
    ##   * `version` is DECLARED only. kenbi cannot read a library's version out of the source,
    ##     so it is reported as declared and never as verified.
    ##   * `requires` IS checked, against the compile line kenbi was given: a requirement the
    ##     build contradicts is an error (the contracts may not describe this build at all), one
    ##     the compile line does not mention is reported as unverified, never as satisfied.
    name*, version*, file*: string
    line*: int
    requires*: seq[tuple[name, value: string]]
    mismatched*: seq[string]     ## "NAME: wanted X, build has Y"
    unverified*: seq[string]     ## requirement names the compile line does not settle

  ContractDecl* = object
    ## ONE ownership contract kenbi resolved onto ONE function declaration, recorded so the
    ## contract *surface* of a library can be published (`kenbi --emit-contracts`) next to
    ## what kenbi was actually able to verify about the implementation behind it.
    ##
    ## Both declaration forms land here — the inline `@frees(p)` above a prototype and the
    ## by-name `@contract F { frees: p }` from an overlay — because a consumer reading the
    ## published set should not be able to tell (and should not care) which form the library
    ## author used; what it must be able to tell is whether the implementation was checked,
    ## which is what `hasBody` feeds.
    fn*: string        ## the key the contract is stored under (`Class::method` for a member)
    effect*: string    ## the contract keyword as declared (`@frees`, `@owns`, `@must_use`, …)
    param*: string     ## the parameter it names, as written (`p`, `$1`, `*p`, `p->f`);
                       ## empty for the whole-function forms (`@owns`, `@must_use`, `@nothrow`)
    file*: string      ## the declaration the contract binds to
    line*: int
    hasBody*: bool     ## this run saw an IMPLEMENTATION of the function, not just a prototype.
                       ## A contract whose body kenbi never saw can only ever be published as
                       ## *declared* — there is nothing here to have verified it against.
    viaOverlay*: bool  ## declared by `@contract F { … }` in a comment-only overlay rather than
                       ## inline above the declaration. Recorded because it says who wrote the
                       ## contract — the library, or a consumer annotating from outside.

  Advisory* = object
    ## A note the deterministic engine does NOT decide — it carries an intent
    ## (lock discipline, lock order, acquire/release, freeform) that a human or
    ## an AI reviewer must verify against the code. Emitted as an advisory-
    ## severity finding; never gates.
    line*: int
    code*: string
    msg*: string

  EffectCall* = object
    symbol*, name*, file*: string
    line*: int
    indirect*: bool

  EffectFunction* = object
    protocolOwner*: string       ## enclosing definition for a required compound block
    protocol*: JsonNode         ## ordered source protocol tree; JSON has structural equality
    symbol*, name*, file*: string
    first*, last*: int
    nameLine*: int               ## line of the function's name, where compilers locate the function
    calls*: seq[EffectCall]
    unsupported*: seq[tuple[line: int, reason: string]]

  EffectUnit* = object
    targetTriple*: string
    pointerWidth*: int
    functions*: seq[EffectFunction]
    requirements*: seq[tuple[symbol, profile: string]]
    inputs*: seq[tuple[path, digest: string]]
    arguments*: seq[string]
    unsupported*: seq[string]

  Program* = object
    effects*: EffectUnit         ## complete call inventory for configured effect checks
    effectMarkers*: seq[tuple[file, profile: string, line, after: int]]
    resources*: Table[string, Resource]
    noreturnLabels*: HashSet[string] ## labels declared `@goto_noreturn` — a terminus that
                                 ## does not return (abort / exit / longjmp). A path that
                                 ## reaches it terminates, so its still-owned obligations are
                                 ## discharged (the process dies; an abort path is not a leak).
                                 ## Suppresses false leaks on error-abort paths.
    finallyLabels*: HashSet[string] ## labels declared `@goto_finally` — the convergence /
                                 ## cleanup funnel where the function's error paths merge. Opt-in
                                 ## single-funnel discipline: an exit that still owns a resource
                                 ## WITHOUT routing through the funnel is FINALLY_BYPASSED (route
                                 ## it via `goto <funnel>`). Merge completeness (double-free /
                                 ## leak at the convergence) is the inferred analysis as usual.
    body*: seq[Stmt]             ## mini-format single body (legacy / engine fixtures)
    funcs*: seq[Func]            ## C/C++: one entry per function (per-function analysis)
    localPtrVars*: HashSet[string] ## USRs of automatic-storage locals whose declared type is a
                                 ## POINTER. A field allocated through one (`n = tree->root;
                                 ## n->buf = acquire()`) is stored into an object that OUTLIVES
                                 ## this frame — only the handle dies at scope exit — so it is
                                 ## not a leak here, exactly as for a pointer PARAMETER. A stack
                                 ## VALUE struct (`S s; s.buf = acquire()`) really does die, and
                                 ## still leaks its field. The two are indistinguishable in the
                                 ## field's display name, which normalises both to `->`.
    quarantined*: HashSet[int]   ## lines carrying `@unsafe` — findings here are
                                 ## suppressed (the author takes responsibility)
    deepFrees*: HashSet[string]  ## releases declared `frees_fields:` — a typed destroy wrapper
                                 ## that releases the object's OWNED FIELDS as well as the
                                 ## object (`DestroyThresholdMap` frees map_id / description /
                                 ## levels before the map). Without the declaration, freeing the
                                 ## container while a field still owns is a LEAK — which is the
                                 ## right default for `free(s)`, and wrong for a destructor that
                                 ## exists precisely to release the graph. Declared, not
                                 ## inferred from the name.
    escapesLines*: HashSet[int]  ## lines carrying `@escapes` — a declared ownership hand-off out
                                 ## of kenbi's view (to external code / a system boundary): the
                                 ## store's ESCAPE_UNCHECKED is suppressed (narrow, unlike @unsafe)
    reallocLines*: HashSet[int]  ## lines carrying `@realloc` — the author declares this fresh-dest
                                 ## `q = realloc(p, n)` reconciles the result with the original handle
                                 ## on the failure path (the `if (q) p = q;` idiom). kenbi cannot
                                 ## verify that reconciliation flatly (it needs the realloc-success /
                                 ## null-check correlation across a join), so it is VOUCHED here; with
                                 ## the vouch kenbi still verifies the block is freed exactly once
                                 ## (leak / double-free). Without it a fresh-dest realloc is
                                 ## REALLOC_UNVERIFIED (default-red). Self-reassign is never vouched
                                 ## by this — it is unconditionally broken (REALLOC_SELF_REASSIGN).
    advisories*: seq[Advisory]   ## advisory intents for the AI/human review layer
    contractPackages*: seq[ContractPackage] ## `@contracts_for` declarations seen in this TU
    contracts*: seq[ContractDecl] ## every ownership contract resolved onto a declaration in
                                 ## this TU — the publishable contract surface (see
                                 ## `kenbi --emit-contracts`). Analysis does not read this;
                                 ## it is a record of what was declared, kept so the declared
                                 ## set can be shipped without re-deriving it from comments.
    # --- coverage / opt-in (`@kenbi`)
    coveredFuncs*: HashSet[string] ## function names opted into kenbi discipline
                                 ## (a `@kenbi` marker above the function)
    allCovered*: bool            ## a file-level `@kenbi` marker covers every function
    coveredBlocks*: seq[tuple[file: string, first, last: int]]
                                 ## `@kenbi` above a STATEMENT inside a function body covers
                                 ## that block only: adoption at the granularity a large
                                 ## function actually gets cleaned up in. The findings inside
                                 ## the line range are kept even though the function around
                                 ## them is not adopted — and the function does NOT become
                                 ## `adopted`, because the rest of it is still unchecked and
                                 ## the coverage numbers must not say otherwise.
    hasKenbiMarker*: bool        ## any `@kenbi` marker present. When false the file is
                                 ## un-adopted: analyze treats it as all-covered (a
                                 ## single-file / fixture check), so opt-in is what a
                                 ## marker turns ON, not a global default flip.
    # --- spatial (bounds) coverage — a SEPARATE opt-in axis (`@spatial`). Independent
    # of `@kenbi` so temporal-only files are never bounds-checked (no false positives on
    # ubiquitous array indexing); a file/function opts in explicitly.
    spatialFuncs*: HashSet[string] ## functions with a `@spatial` marker
    spatialAll*: bool              ## a file-level `@spatial` marker covers every function
    # --- concurrency (lock discipline) coverage — a SEPARATE opt-in axis (`@threadsafe`).
    # Independent of `@kenbi`/`@spatial` so non-concurrent files are never lock-checked; a
    # `@guarded_by(field: lock)` access without the lock held gates only when opted in.
    concurrentFuncs*: HashSet[string] ## functions with a `@threadsafe` marker
    concurrentAll*: bool              ## a file-level `@threadsafe` marker covers every function
    lockOrder*: seq[tuple[before, after: string]] ## declared `@lock_order(a < b)` pairs (display
                                 ## names). The lock-balance pass VERIFIES the code respects them:
                                 ## acquiring `before` while `after` is already held is an AB-BA
                                 ## deadlock (LOCK_ORDER_VIOLATION) — a guarantee Rust does NOT make.
    # --- uninitialized-use (definite-assignment) coverage — a SEPARATE opt-in axis
    # (`@initcheck`). A read of a local that is not definitely assigned on every path is
    # USE_OF_UNINITIALIZED. Opt-in so existing files are never init-checked.
    initFuncs*: HashSet[string]       ## functions with an `@initcheck` marker
    initAll*: bool                    ## a file-level `@initcheck` marker covers every function
    # --- type-confusion (tagged-union discriminant) coverage — a SEPARATE opt-in axis
    # (`@typecheck`). A `@variant(member : tag == value)` member read/written without the tag
    # proven `== value` on the path is TYPE_CONFUSION. Opt-in so other files are unaffected.
    typecheckFuncs*: HashSet[string]  ## functions with a `@typecheck` marker
    typecheckAll*: bool               ## a file-level `@typecheck` marker covers every function

proc relined*(s: Stmt, ln: int): Stmt =
  ## A copy of `s` (and of everything nested in it) reported at line `ln`. Used when a body is
  ## SPLICED at a call site — a lambda's — so the finding names the call that ran it, the way a
  ## callee's declared effects are reported at their callsite rather than inside the callee.
  new(result)
  result[] = s[]
  result.line = ln
  case result.kind
  of stIf:
    result.thenBody = @[]
    result.elseBody = @[]
    for k in s.thenBody: result.thenBody.add relined(k, ln)
    for k in s.elseBody: result.elseBody.add relined(k, ln)
  of stLoop:
    result.loopBody = @[]
    for k in s.loopBody: result.loopBody.add relined(k, ln)
  of stSwitch:
    result.cases = @[]
    for c in s.cases:
      var nc: seq[Stmt]
      for k in c: nc.add relined(k, ln)
      result.cases.add nc
  of stTry:
    result.tryBody = @[]
    for k in s.tryBody: result.tryBody.add relined(k, ln)
    var nh: seq[seq[Stmt]]
    for h in s.handlers:
      var one: seq[Stmt]
      for k in h: one.add relined(k, ln)
      nh.add one
    result.handlers = nh
  else: discard

# The instructions that give an assignment target a NEW identity. Lowering an assignment that
# produced none of these for the target means the RHS was a shape kenbi cannot place, so the
# target is UNBOUND (ikRebind) rather than left naming what it named before; the engine uses
# the same set to decide when a handle stops being of unknown provenance.
const bindingInstrs* = {
  ikAlloc, ikCopy, ikRealloc, ikInterior, ikLocalAddr, ikArenaAlloc, ikRaiiAlloc,
  ikRaiiMove, ikMaybeFreedResult, ikSetNull, ikReArm, ikOwnsOut}
