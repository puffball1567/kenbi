// @kenbi file
// REFERENCE COUNTING: the retain and release functions themselves are checked against the
// declaration — one increment, one decrement, and the object freed exactly where the count
// is found to be zero — and so is the function that allocates an object and sets its first
// count. Plain and atomic counters.
#include <stdlib.h>
#include <stdatomic.h>

// @allocator rc::heap { alloc: malloc calloc, free: free }

// --- A: retain forgets to count --------------------------------------------
// @refcounted A { count: refs, retain: a_retain, release: a_release }
typedef struct A { int refs; } A;
void a_retain(A *a) { (void)a; }   //EXPECT COUNT_RETAIN_MISMATCH
// @frees(a)
void a_release(A *a) { if (--a->refs == 0) free(a); }

// --- B: release frees without testing ---------------------------------------
// @refcounted B { count: refs, retain: b_retain, release: b_release }
typedef struct B { int refs; } B;
void b_retain(B *b) { b->refs++; }
// @frees(b)
void b_release(B *b) { b->refs--; free(b); }   //EXPECT COUNT_RELEASE_MISMATCH COUNT_RELEASE_MISMATCH

// --- C: release never frees --------------------------------------------------
// @refcounted C { count: refs, retain: c_retain, release: c_release }
typedef struct C { int refs; } C;
void c_retain(C *c) { c->refs++; }
void c_release(C *c) { c->refs--; }   //EXPECT COUNT_RELEASE_MISMATCH

// --- D: release touches the object after the decrement -----------------------
// @refcounted D { count: refs, retain: d_retain, release: d_release }
typedef struct D { int refs; int n; } D;
void d_retain(D *d) { d->refs++; }
// @frees(d)
void d_release(D *d) {
    if (--d->refs > 0) { d->n = 0; return; }   //EXPECT COUNT_USE_AFTER_RELEASE USE_AFTER_MOVE
    free(d);
}

// --- E: atomic counter, null guard, early return: correct --------------------
// @refcounted E { count: refs, retain: e_retain, release: e_release, destroy: e_destroy }
typedef struct E { atomic_int refs; char *name; } E;
E *e_retain(E *e) {
    if (!e) return NULL;
    atomic_fetch_add(&e->refs, 1);
    return e;
}
// @frees(e)
// @frees(e.name)
static void e_destroy(E *e) { free(e->name); free(e); }
// @frees(e)
// @frees(e.name)
void e_release(E *e) {
    if (!e) return;
    if (atomic_fetch_sub(&e->refs, 1) != 1) return;
    e_destroy(e);
}
// @owns
E *e_new(void) {
    E *e = calloc(1, sizeof(E));
    if (!e) return NULL;
    atomic_init(&e->refs, 1);
    return e;
}
// @owns
E *e_new2(void) {
    E *e = calloc(1, sizeof(E));
    if (!e) return NULL;
    e->refs = 1;
    return e;
}
// @owns
E *e_forgot(void) {
    E *e = calloc(1, sizeof(E));
    return e;   //EXPECT COUNT_NO_SHARE
}
// @owns
E *e_share(E *e) { return e_retain(e); }
// @owns
E *e_share_bad(E *e) { return e; }   //EXPECT COUNT_NO_SHARE
void e_destroy_elsewhere(E *e) { e_destroy(e); }   //EXPECT COUNT_DIRECT_FREE
// @owns(out)
int e_make(E **out) {
    E *e = e_new2();
    if (!e) return -1;
    *out = e;
    return 0;
}
int e_user(int k) {
    E *e = NULL;
    if (e_make(&e) != 0) return 1;   //EXPECT COUNT_LEAK
    switch (k) {
    case 0: e_release(e); return 0;
    case 1: break;
    default: e_release(e); return 2;
    }
    do { k++; } while (k < 3);
    e_release(e);
    return 3;
}
