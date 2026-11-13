// The annotation reference, served as the `kenbi://annotations` resource so an
// agent can learn how to annotate before (re)running the checker. Kept in sync
// with the engine; annotations are NOT trusted — the body is checked against them.

export const ANNOTATIONS = `# kenbi annotation reference

This lists the **implemented** directives only — what the current checker
actually verifies. Planned syntax (general lifetimes/borrow, protocol typestate,
argument-level ownership) is deliberately kept out so an agent never annotates
against a spec the engine can't yet check. Keep it that way: add an entry here
only when its check ships.

Annotations are ordinary C/C++ comments. A directive fires **only** when its
\`@\`-keyword is the *first token* of the comment body (\`// @move x\`,
\`/* @mem ... */\`). Prose that merely mentions "@move" is not a directive.

kenbi does not trust these annotations — it checks the implementation against
the declared intent and reports where they disagree.

## Resource declaration
- \`// @mem <scope::name> { size: <fn>, free: <fn>, owner: <var> }\`
  Declare a logical owned resource. \`free:\` names the required deallocator;
  freeing with a different function is \`WRONG_DEALLOCATOR\`. An owned resource
  never freed/moved by scope end is a \`LEAK\`.

## Ownership transfer / duplication
- \`// @move <resource>\` — the annotated call moves the value out (e.g. into a
  container/channel). Using it afterwards is \`USE_AFTER_MOVE\`.
- \`// @copy <resource>\` — the assignment is a deep copy: the target gets a NEW
  owned obligation (it does not alias the source).

## Null safety (Rust \`Option<T>\`)
- \`// @nullable\` / \`// @nonnull\` on a declaration. Dereferencing a nullable
  pointer (\`*p\`, \`p->x\`, \`p[i]\`) without a null-check is \`NULL_DEREF\`.
  Flow-sensitive: \`if (p)\`, \`if (!p) return;\`, \`if (p == NULL)\` narrow it.

## Must-use return (Rust \`#[must_use]\`)
- \`// @must_use\` above a function declaration. A call whose result is discarded
  (a bare statement — not assigned, returned, passed as an argument, or tested)
  is \`UNUSED_MUST_USE\`. Use for error codes and allocations that must not be
  dropped.

## Bounds axis opt-in (spatial)
- \`// @spatial\` above a function (or at file level). Turns ON the SEPARATE bounds
  axis for that scope, independent of \`@kenbi\`: an untrusted scalar parameter used to
  index a buffer (or size a buffer write like memcpy) must have a runtime bound check
  present on the path (an if-guard \`idx < N\`, a loop condition, \`% n\`, a clamp or a
  mask), else it is \`UNVALIDATED_INDEX\` / \`UNVALIDATED_SIZE\`. The bound must also be
  APPROPRIATE — it has to cover the buffer's size; a present-but-too-loose check (e.g.
  bounding a 64-byte buffer by 1000) is \`INAPPROPRIATE_BOUND\`. kenbi compares the bound
  against a fixed-size buffer's size (constant / identity match, not range arithmetic)
  and never elides a check.

## Signature contract
- \`// @frees(<param>)\` above a function. Callsites then treat the call as
  freeing that argument (composing with double-free / leak), and the function's
  own body is checked: if it does not actually free the parameter that is
  \`CONTRACT_NOT_HONORED\` (declared intent vs. implementation).

## Ownership contracts on a signature (the cross-function / cross-file boundary)
- \`// @borrows(<param>)\` — the callee only reads / writes through the pointer and
  never frees or keeps it. Callsites: passing an owned pointer is a plain use (not an
  escape). Body: freeing the parameter is \`BORROW_FREED\`, moving it away is
  \`BORROW_MOVED\`.
- \`// @moves(<param>)\` — the callee takes the value out (a channel / thread handoff).
  Callsites: the argument is moved; using it afterwards is \`USE_AFTER_MOVE\`, moving it
  again is \`DOUBLE_MOVE\`.
- \`// @adopts(<param>)\` — a CONSUMER takes over the release while the object stays valid:
  the container hand-off (\`list_append(list, value)\`, a registry \`register(x)\`), where the
  collection frees the element when it is destroyed. The caller no longer owes the release
  (not a leak) and may still read the value — putting a pointer in a list does not
  invalidate it, which is why \`@moves\` is the wrong word here and \`@frees\` wronger.
  Releasing it in the caller afterwards is \`DOUBLE_FREE\`.
- \`// @owns\` above a factory — the call returns a fresh owned object; the callsite must
  free it exactly once (declare it with \`@mem\`, else it is default-red).
- \`// @owns(p)\` on a C++ \`T *&p\` reference parameter / \`// @owns(*p)\` on a C \`T **p\` —
  the callee allocates INTO its out-parameter: at the callsite the argument variable
  becomes an owned origin (declare it with \`@mem\` above the call); in the body the store
  into the parameter is the declared hand-out, not a leak.
- Accessor forms name WHAT is transferred: \`@frees(*p)\` (the pointee of an
  out-parameter), \`@frees(p.f)\` / \`@frees(p->f)\` (a struct field), \`@frees(arr[2])\`
  (a constant array element), \`@frees(g)\` (a file-scope global the function releases).
- A struct or array passed BY VALUE whose fields / constant elements hold owned pointers
  hands every one of them across the call: \`@borrows(s)\` is a read, \`@moves(s)\` a
  move, \`@frees(s)\` a release, and no contract the usual \`UNCONTRACTED_ESCAPE\` per field
  (never a silent hand-off).
- A call THROUGH A FUNCTION POINTER takes the contract its declared \`@calls(f, g, ...)\`
  targets agree on (see the concurrency axis for the directive); targets that disagree, or
  an undeclared pointer, leave the argument uncontracted.
- Local aliases are followed without annotation: \`p = &data\` then \`*p = x\` / \`y = *p\`
  act on \`data\`; a C++ reference \`T *&r = data\` IS \`data\`.
- A contract on a MEMBER FUNCTION is keyed \`Class::method\` (two classes' \`take\` never
  collide). A virtual call through a base pointer / reference dispatches to the class the
  object was constructed as when that construction is in view (\`Base *b = new Derived\`,
  \`const Base &b = Derived()\`) — \`Derived::method\`'s contract applies; a base whose
  dynamic type is not in view (a parameter) stays uncontracted.
- A pointer that crosses a callee with NO contract is \`UNCONTRACTED_ESCAPE\`; freeing an
  incoming parameter with no contract is \`UNCONTRACTED_RELEASE\`. Declare, don't infer.
- \`// @escapes\` on a store line (\`*slot = buf;\`) — the obligation leaves through that
  store on purpose (an out-parameter, a registry); without it the store is
  \`ESCAPE_UNCHECKED\`.
- \`q = realloc(p, n)\` ties the two handles: on OOM realloc returns NULL and the block is
  still \`p\`'s, on success it is \`q\`'s and \`p\` is dangling. The null test of the RESULT
  settles that — \`if (q) p = q;\`, or \`if (!q) { free(p); return; } p = q;\` — and kenbi
  verifies the idiom with no annotation. Touching either handle before the test is
  \`REALLOC_UNVERIFIED\`; \`// @realloc\` on the realloc line vouches for a reconciliation
  kenbi cannot see. \`p = realloc(p, n)\` is always \`REALLOC_SELF_REASSIGN\` (on OOM the only
  handle is overwritten).

## C++ owners (RAII) and exceptions
- \`// @raii\` above a class / struct / class template, or \`// @raii(Name)\` by name (the
  class may be declared in a header) — its instances OWN a resource the destructor
  releases (declared, then VERIFIED: a raw member a constructor allocates into must be
  released by the destructor — \`LEAK\` if it never is, \`DOUBLE_FREE\` if twice). A local or a by-value
  / \`&&\` parameter is an owner (never a \`LEAK\`); a \`&\` / \`const &\` parameter is a
  borrow. \`std::move(x)\` moves it out: using \`x\` afterwards is \`USE_AFTER_MOVE\`. A
  struct whose fields are owners holds them (one owner per field, also through \`this\`
  inside member functions).
- The class's COPY semantics are checked with it (the rule of three). Copying an \`@raii\`
  class that declares no copy constructor / copy assignment operator of its own is
  \`MISSING_COPY_CONTROL\` — the implicit member-wise copy hands both objects the same
  pointer and both destructors release it. Write the operation, or \`= delete\` it
  (\`= default\` does not help: a defaulted copy IS the member-wise copy). The finding is
  at the COPY, so a class nobody copies reports nothing.
- An \`operator=\` that RELEASES a member and only then reads its source is
  \`SELF_ASSIGN_UNSAFE\`: \`x = x\` is legal C++ and that read is of memory just freed.
  Guard it (\`if (&other != this)\`), or build the new value before releasing the old one.
- \`delete p\` through a pointer to a class whose destructor is not virtual is
  \`DELETE_NONVIRTUAL_BASE\` when the object was created as a derived class (undefined
  behaviour: the derived destructor never runs), and also when its dynamic type is not in view
  and other classes derive from that class. Declare the base destructor \`virtual\`.
- \`std::unique_ptr\` and \`std::shared_ptr\` are built-in owners (a shared_ptr COPY is a
  second live handle; a MOVE empties the source). \`auto p = std::make_unique<T>(...)\`
  and a custom deleter are owners too. The seam: \`.get()\` hands out a BORROW (freeing
  it or passing it to a \`@frees\` callee is \`FREE_INTERIOR\`), \`.release()\` hands out
  OWNERSHIP (a raw resource you must now free once), \`.reset(p)\` releases the current
  resource (a borrow taken from it before now dangles: \`USE_AFTER_FREE\`) and takes \`p\`,
  which stays usable as a borrow of the owner. A move BETWEEN owners
  (\`b = std::move(a)\`) keeps the resource: a borrow taken from \`a\` is still valid (it
  is \`b\`'s now); only the handle \`a\` is moved-from.
- Exceptions are exits. \`throw\` abandons every raw owner still held (\`LEAK\`). A call to
  a callee with NO nothrow guarantee, and a plain \`new\` (bad_alloc), may unwind: a raw
  owner still held there is \`LEAK_ON_THROW\`, an undischarged \`@frees\` obligation too.
  RAII owners are exempt (unwinding runs their destructors) — the idiomatic fix.
  The nothrow proofs are DECLARED: \`noexcept\` / \`throw()\` on the declaration, glibc's
  \`__THROW\` (malloc / free / memcpy ...), or the vouch \`// @nothrow\` above a
  declaration; \`// @nothrow(name)\` vouches a callee by name (\`@nothrow(operator*)\`);
  \`// @nothrow(new)\` declares the allocation-failure policy (OOM terminates, \`new\`
  never unwinds); \`-fno-exceptions\` in the compile args turns the axis off. C files
  never carry it.
- \`longjmp\` is an exit that runs NOTHING on the way out (C and C++). A call to
  \`longjmp\` / \`siglongjmp\` always leaves; a call to a function declared \`// @longjmps\`
  may. A raw owner still held there is \`LEAK_ON_LONGJMP\`; in C++ an object in scope with a
  non-trivial destructor is \`LONGJMP_SKIPS_DESTRUCTOR\` (undefined behaviour; triviality is
  clang's answer, so \`std::string\` counts and \`std::array<int, 3>\` does not). A function
  that can reach a longjmp — directly or through a \`@longjmps\` callee — must declare
  \`// @longjmps\` itself, else \`UNDECLARED_LONGJMP\`: the declaration travels up to every
  caller. A library function is declared by name (\`// @longjmps(png_error)\`, or
  \`longjmps\` in \`@contract\`). A function that calls \`setjmp\` is the landing site, not
  modelled yet: \`UNSUPPORTED_SETJMP\`. Fix: release before the call, keep objects with a
  destructor out of the scopes a jump can leave, or report the error another way.
- A LAMBDA body runs where it is CALLED: \`auto v = [..]{..};\` defines it, each \`v()\`
  runs it (so calling a cleanup lambda twice is a \`DOUBLE_FREE\`, and never calling it leaves
  the \`LEAK\`). A lambda handed to a callee or kept in a \`std::function\` runs at a time
  kenbi cannot place: one that allocates or releases is refused (\`UNSUPPORTED_CONSTRUCT\`).
  A range-for is a loop like any other. A statement kenbi does not model is never silently
  dropped — if it contains an allocation or a release it is refused the same way.
- \`try\` / \`catch\`: every unwinding exit inside the body lands in the handlers, which are
  checked from their join (a handler that forgets the owner: \`LEAK\`; one that frees
  what the body already freed: \`DOUBLE_FREE\`). A literal \`throw e\` is consumed by the
  first handler naming EXACTLY e's type (\`catch (T)\` / \`catch (const T&)\`); a base-class
  handler or a conversion is not matched, and what a may-throw CALL throws is unknown —
  those propagate unless a \`catch (...)\` ends the chain.

## Adoption marker
- \`// @kenbi\` above a function, or at file level — the unit is under kenbi discipline:
  an undeclared heap resource there is an error, not just a note, and the unit counts in
  the coverage report. A file with no marker is checked as a whole (single-file mode).

## Your project's own allocator family (declare once, in the header everyone includes)
- \`// @allocator <scope::name> { alloc: f g h, realloc: r, free: z }\` — nearly every C
  project wraps malloc (\`AcquireMagickMemory\`, \`xmalloc\`, \`pool_get\` …). Until its
  wrappers are declared kenbi has no vocabulary for them and says nothing about that memory.
  Declared, every result is a tracked owned resource: unreleased is a \`LEAK\`, released
  twice \`DOUBLE_FREE\`, released with anything but the declared function
  \`WRONG_DEALLOCATOR\`. Several names per field, whitespace-separated; one line per family
  (aligned / pooled allocations are their own family — do not mix them).
- \`free_returns_null:\` instead of \`free:\` when the release hands back NULL and the house
  style is \`p = release(p)\`: p then owns nothing, and releasing it again is the defined
  no-op rather than a double free.
- \`p = NULL\` after a release is understood the same way (\`free(NULL)\` does nothing in C),
  so the standard defensive idiom is not reported. Nulling the ONLY handle without releasing
  it is still a \`LEAK\`.

## Arena / region ownership
- \`// @arena <name> { create: <fn>, alloc: <fn>, free: <fn> }\` — declares a region: the
  \`create\` result is an owned arena (freed exactly once by \`free\`), every \`alloc\` result
  is an object OWNED BY THE ARENA: never freed individually (\`BORROW_FREED\`), never a
  leak, and dead once the arena is destroyed — using it after is \`BORROW_OUTLIVES_OWNER\`.
- \`// @arena_alloc(<arena-param>)\` above a wrapper — its result borrows from the arena
  passed as that argument (the cross-function form of \`alloc\`).

## Opting in: file, function, or BLOCK
- \`// @kenbi\` marks what is under discipline; findings outside it are dropped, so adoption is
  gradual. The marker binds to whatever it sits above: a FILE (at the top, no function below),
  a FUNCTION, or — when it sits above a statement inside a body — that BLOCK alone (a bare
  \`{ … }\`, or an \`if\` / \`for\` / \`while\` / \`switch\` and its body).
- A block under discipline does NOT make its function adopted: the coverage result counts such
  blocks separately (\`blocksAdopted\`), because the rest of the function is still unchecked.
- Use it to adopt one part of a function that is too large to clean up at once.

## Shipping contracts for a library
- \`// @contracts_for <library> { version: <v>, requires: NAME=VALUE … }\` at the top of a
  contract overlay — whose contracts these are and what build they were written against.
- \`requires:\` is CHECKED against the compile line: a build that contradicts one is
  \`CONTRACT_PACKAGE_MISMATCH\` (an error — the contracts were written for a different build),
  and a condition the compile line does not settle is reported as unverified, never satisfied.
- \`version:\` is carried as DECLARED. kenbi cannot read a library's version out of source and
  does not pretend to.
- \`--format=json\` carries \`contractPackages\` with \`versionDeclared\`, \`requires\`,
  \`mismatched\`, \`unverified\` and \`appliesToThisBuild\`.

## What "GREEN" does NOT mean
- \`green\` = the boundaries are declared: safe GIVEN the contracts it rests on (modular trust).
- \`verified\` = a strict subset of \`green\` whose whole contracted-dependency closure is also
  covered — nothing taken on trust.
- \`trustedFrontier\` = the uncovered callees a GREEN rests on. Declaring a contract on an
  uncovered callee moves the caller RED -> GREEN and puts that callee here.
- \`unsafeVouches\` = every \`@unsafe\` that actually suppressed a finding, with its function and
  line. Such a function is GREEN but never \`verified\`. An operation kenbi cannot verify can
  therefore never read as verified because someone annotated it.
- All of it is in \`--format=json\`, plus per-entry-point \`flows\` with their \`blockers\`.

## Null state
- Three values: non-null (the optimistic default, including a fresh allocation result), MAYBE
  null (a \`@nullable\` declaration, or a merge of both on a join), and known NULL (\`p = NULL\`
  on a tracked pointer, or the result of a release declared \`free_returns_null\`).
- Dereferencing a MAYBE-null pointer is \`NULL_DEREF\` ("possibly-null"); dereferencing one kenbi
  knows IS null is also \`NULL_DEREF\`, said separately ("which is null here") — the defensive
  \`free(p); p = NULL;\` followed by a read, or a read after a release that hands back NULL.
- A known-null pointer owns nothing and releasing it is the defined no-op, so the defensive
  idiom itself is never a finding.

## Allocator families with typed destructors
- \`free:\` / \`free_returns_null:\` accept SEVERAL release names, and all of them are valid
  releases of the family: real projects allocate with one generic wrapper and release through
  typed destructors around it (\`DestroyKernelInfo\` ends
  \`kernel = RelinquishMagickMemory(kernel); return kernel;\`). Releasing with a name the family
  does NOT declare is still \`WRONG_DEALLOCATOR\`.
- \`frees_fields: <fn> …\` — those releases also discharge the object's owned FIELDS, which is
  what a destructor is for. Without it, freeing the container while a field still owns is a
  \`LEAK\` — the right default for a plain \`free(s)\`, and wrong for a destructor. Declared,
  never inferred from the name.
- A builder whose error paths are written \`return(DestroyX(obj));\` returns NULL, not a dangling
  pointer, when the release is declared \`free_returns_null\` — so its callers' use of the result
  is not a use-after-free risk.

## Declaring a contract from OUTSIDE the file
- \`// @contract <Fn> { frees: p, borrows: q r, moves: s, owns, owns_out: t, must_use, nothrow, longjmps }\`
  — the same ownership contracts as the inline annotations, but attached to a function BY NAME.
  The inline forms have to sit above a declaration, which a project you may not edit does not
  offer; this form lives in a force-included, comment-only overlay header, next to
  \`@allocator\` and \`@list\`.
- Keys may repeat and may list several parameters (\`borrows: image exception\`). A key with no
  value is the whole-function form (\`owns\` = the RETURN is a fresh owned object; \`must_use\`;
  \`nothrow\`; \`longjmps\`). Accessor forms work as inline (\`*p\`, \`p->f\`, \`arr[2]\`).
- Parameters may be named by POSITION — \`$1\`, 1-based — which is usually what you need: C
  headers commonly declare parameters unnamed, and the call sites that need the contract see
  only that prototype.
- It is CHECKED, not trusted, through the same binding as the inline form: a \`frees:\` contract
  on a function whose body is in the translation unit is verified against it
  (\`CONTRACT_NOT_HONORED\` if it does not free), freeing a declared \`borrows:\` parameter is
  \`BORROW_FREED\`, and declaring a borrow leaves the caller still owing the release (so a
  pointer handed over and never freed becomes a visible \`LEAK\`).
- A name the translation unit never declares is skipped silently — one overlay covers a whole
  project. A name it DOES declare with a parameter the signature lacks binds nothing, so the
  boundary stays uncontracted (the safe direction) and a \`CONTRACT_UNBOUND\` advisory says why.
- For a FACTORY, prefer \`@allocator\`: adding the function to the family's \`alloc:\` list also
  names the resource and its deallocator, so leaks and \`WRONG_DEALLOCATOR\` are checked too.

## Intrusive collections (linked lists)
- \`link: <field>\` inside a \`@mem\` block, or \`// @list <Type> { link: <field> }\` for a whole
  record TYPE (the form that reaches allocations made through an \`@allocator\` family) — the
  resource is a NODE of a collection chained through that field. Its origin then stands for the
  whole chain: a walk (\`cur = cur->next\`) binds another cursor on the same collection instead
  of a pointer kenbi cannot place, and a release in the walk removes an ELEMENT.
- \`// @drains(<head>)\` on a loop — that loop releases every element of the collection rooted
  at \`<head>\`. Verified, not trusted: a loop that releases nothing is \`CONTRACT_NOT_HONORED\`,
  a collection nothing drains is a \`LEAK\`, \`free(cur); cur = cur->next;\` is a
  \`USE_AFTER_FREE\`, releasing a cursor twice before it advances is a \`DOUBLE_FREE\`, and
  every cursor dangles once the collection is drained.

## Bounds axis (spatial) — sizes and bounds
- \`// @counted_by(<buf>: <len>)\` above a function (stack several on one function) — the
  buffer parameter \`buf\` holds \`len\` elements (\`len\` is another parameter; a field form
  \`@counted_by(b->buf: b->cap)\` and an offset form \`b->mask + 1\` for power-of-two ring
  buffers work too). A bound naming \`len\` then covers \`buf\`; without it a symbolic
  buffer has no known size and every index / size sink is \`UNVALIDATED_INDEX\` /
  \`UNVALIDATED_SIZE\`. Guard arithmetic must be overflow-safe: \`i + 4 <= n\` on an unsigned
  \`i\` is not credited (wrap), write \`n >= 4 && i <= n - 4\`; a signed index needs
  \`i >= 0\` too (\`INDEX_MAYBE_NEGATIVE\`); a bound that does not cover the buffer is
  \`INAPPROPRIATE_BOUND\`.

## Invariant axis (declared data-structure invariants, under \`@spatial\`)
- \`// @invariant(<field> <rel> <size>)\` above a function, \`rel\` in \`<\`, \`<=\`, or a lower
  form \`<field> >= -1\` — e.g. \`@invariant(parser->toknext <= num_tokens)\`. The field is
  PROTECTED: every write to it must carry \`@maintains\`, else \`UNGUARDED_INVARIANT_WRITE\`;
  and an index bounded by the field is covered through the relation (chaining).
- \`// @maintains(<same relation>)\` on the write line — you claim the write preserves the
  invariant; kenbi VERIFIES it (\`p->count++\` under \`if (p->count < cap)\` passes, an
  unguarded increment is \`INVARIANT_NOT_MAINTAINED\`).

## Definite-assignment axis (opt-in)
- \`// @initcheck\` above a function or at file level — a scalar / pointer local declared
  without an initializer must be assigned on EVERY path before it is read, else
  \`USE_OF_UNINITIALIZED\` (\`if (c) v = 1; return v;\` is refused; assign on both branches or
  at the declaration).

## Type-confusion axis (tagged unions, opt-in)
- \`// @typecheck\` above a function or at file level, plus
  \`// @variant(<member>: <tag> == <value>)\` per union member —
  \`@variant(n->u.p: n->tag == 1)\`. Reading or writing a variant member on a path where
  its discriminant is not proven (\`if (n->tag == 1)\`, or a \`case 1:\` on the tag) is
  \`TYPE_CONFUSION\`.

## Concurrency axis (locks / deadlock, opt-in)
- \`// @threadsafe\` above a function or at file level turns the axis on. The held-set of
  locks is tracked flow-sensitively from \`pthread_mutex_lock\` / \`unlock\` (and
  \`trylock\`: held only on the success branch); a lock is proven held only if held on
  EVERY path (intersection at joins), hazards are reported if possible on ANY path.
- \`// @guarded_by(<field>: <lock>)\` above a function — every access to \`field\` in it
  needs \`lock\` held: \`UNGUARDED_ACCESS\`. Or \`// @guarded_by(<lock-field>)\` on a struct
  member — per type: \`base->data\` needs \`base->lock\`. Taking the ADDRESS of a guarded
  field (\`&c->data\`) is \`GUARDED_ESCAPE\` (the alias escapes the lock's reach).
- Balance: a lock still held at an exit is \`LOCK_LEAKED\`; re-acquiring a held lock is
  \`DOUBLE_LOCK\` (self-deadlock; a recursive mutex takes \`@unsafe\`); releasing a lock not
  provably held is \`UNLOCK_WITHOUT_LOCK\`.
- \`// @acquires(<lock>)\` / \`// @releases(<lock>)\` above a function — it hands the lock
  to the caller held / requires it held at entry and drops it. VERIFIED in the body
  (\`LOCK_NOT_ACQUIRED\` if not held on every exit) and consumed at call sites (the caller's
  held-set changes across the call, so a cross-function AB-BA is caught).
- \`// @requires_lock(<lock>)\` above a callee — every call to it must hold the lock
  (\`REQUIRED_LOCK_NOT_HELD\`); global (\`g_lock\`) and struct-field (\`s->lock\`, resolved
  through the argument) forms.
- \`// @lock_order(<a> < <b>)\` at file level — acquiring \`a\` while \`b\` is held is
  \`LOCK_ORDER_VIOLATION\` (AB-BA deadlock). Two conflicting declarations are
  \`LOCK_ORDER_CONFLICT\`.
- \`// @lock_class(<X>)\` on a lock DECLARATION (a global, or a struct field) names its
  identity class, so \`@acquires(X)\` / \`@lock_order(X < Y)\` match by that stable name
  across functions and files (two \`static\` locks with one name stay distinct). Holding TWO
  instances of one class needs a canonical order (\`if (a < b) lock a, b; else lock b, a\`),
  else \`SAME_CLASS_NO_ORDER\`.
- \`// @calls(<fn>, ...)\` on a function-pointer declaration — its callable targets. A call
  through a pointer under a lock with no declared targets is \`UNDECLARED_INDIRECT_CALL\`;
  assigning it a function outside the set is
  \`UNDECLARED_FN_TARGET\`. Declared targets contribute their lock effects to the check.
- Outside a \`@threadsafe\` scope these directives are ADVISORY only (\`GUARDED_BY\`,
  \`REQUIRES_LOCK\`, \`ACQUIRES\`, \`RELEASES\`, \`LOCK_ORDER\` at severity "advisory" — they
  never gate). \`// @llm <text>\` is a freeform reviewer instruction (\`LLM_REVIEW\`).

## Goto vocabulary (optional — declare a goto's structured meaning)
- A forward cleanup ladder (\`if (!p) goto fail; ... fail: free(p);\`) is modelled with no
  annotation. A backward goto-loop, a jump into a nested block, or a computed goto is
  refused: \`UNSTRUCTURED_GOTO\`.
- \`// @goto_noreturn\` on a label — a non-returning terminus (abort / exit): paths reaching
  it are not leaks.
- \`// @goto_finally\` on a label — the single cleanup funnel: an owning exit that bypasses
  it is \`FINALLY_BYPASSED\`.
- \`// @goto_backward\` on a goto — a declared loop back-edge, analysed as a loop instead
  of refused.

## Escape hatch
- \`// @unsafe\` suppresses findings on that line (you take responsibility). An
  \`@unsafe\` that suppresses nothing is reported as \`STALE_UNSAFE\`.

## Comments next to annotations
- Do not repeat in an ordinary comment what an annotation already declares — who owns
  a resource, which function frees it, that a parameter may be null, which lock guards
  a field. kenbi checks the annotation against the code; a prose copy is never checked,
  and once the code changes it silently disagrees with the annotation. With
  \`/* @mem app::buf { free: free, owner: p } */\` on the allocation, write the release
  as \`free(p);\`, not \`free(p);  /* release the buffer */\`.
- Keep ordinary comments for what the vocabulary cannot say: why the design is this
  way, constraints from outside the code, intent kenbi does not decide (or \`@llm\` for a
  directive a reviewer should verify).

## Workflow
1. Write annotated C/C++.
2. Run \`check_memory_safety\` on the file(s).
3. Fix what kenbi reports, re-run until it reports no findings. The checker is the
   judge — the annotations are claims it verifies, which catches mistakes (and LLM
   hallucinations) that a comment alone would hide. A result without findings covers
   only the scope the summary lists (the checks that ran, on which functions, and what
   it rests on without checking); it is not a verdict on anything outside it.
`;
