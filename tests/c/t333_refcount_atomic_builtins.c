// @kenbi file
// REFERENCE COUNTING with the compiler's atomic builtins. A function that yields the value
// AFTER the decrement (`__sync_sub_and_fetch`) finds the last share at 0; one that yields the
// value BEFORE it (`__atomic_fetch_sub`) finds it at 1 — testing that one against 0 never
// frees the object where it should. A backward `goto` is refused, not guessed at.
#include <stdlib.h>
// @allocator rc::heap { alloc: malloc calloc, free: free }
// @refcounted S { count: refs, retain: s_get, release: s_put }
typedef struct S { int refs; } S;
S *s_get(S *s) { __sync_fetch_and_add(&s->refs, 1); return s; }
// @frees(s)
void s_put(S *s) { if (__sync_sub_and_fetch(&s->refs, 1) == 0) free(s); }
// @refcounted T { count: refs, retain: t_get, release: t_put }
typedef struct T { int refs; } T;
void t_get(T *t) { __atomic_fetch_add(&t->refs, 1, __ATOMIC_RELAXED); }
// @frees(t)
void t_put(T *t) { if (__atomic_fetch_sub(&t->refs, 1, __ATOMIC_ACQ_REL) == 1) free(t); }
// @refcounted U { count: refs, retain: u_get, release: u_put }
typedef struct U { int refs; } U;
void u_get(U *u) { __atomic_fetch_add(&u->refs, 1, __ATOMIC_RELAXED); }
// @frees(u)
void u_put(U *u) { if (__atomic_fetch_sub(&u->refs, 1, __ATOMIC_ACQ_REL) == 0) free(u); }   //EXPECT CONTRACT_NOT_HONORED COUNT_RELEASE_MISMATCH COUNT_RELEASE_MISMATCH
void back(S *s) {
again:
    s_get(s);
    s_put(s);
    if (s->refs > 9) goto again;   //EXPECT COUNT_UNPROVEN UNSTRUCTURED_GOTO
}
