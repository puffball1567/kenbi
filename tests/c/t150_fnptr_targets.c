// @threadsafe
// CONCURRENCY v3 STAGE 4 — function pointers are NOT an opaque residual. The implementer DECLARES
// the callable target set with `@calls(f, g, ...)` (only they know it); kenbi then (a) refuses a
// lock-holding indirect call through a pointer with NO declared targets (its lock behaviour is
// unverifiable — a deadlock cannot be ruled out), (b) resolves a DECLARED indirect call to its
// targets' `@acquires` locks and runs the same AB-BA order check as a direct acquire, and (c)
// CHECKS that the pointer is only ever assigned a declared target (annotation-vs-implementation).
// The escape is to DECLARE the targets, never `@unsafe`. A guarantee Rust does not make.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

static pthread_mutex_t a;   // @lock_class(net_table)
static pthread_mutex_t b;   // @lock_class(disk_table)

// A globally declared order: net before disk.
// @lock_order(net_table < disk_table)   //EXPECT LOCK_ORDER

// Two callbacks that acquire a lock, declared via @acquires (verified in @threadsafe scope).
// @acquires(disk_table)
void take_disk(void) { pthread_mutex_lock(&b); }
// @acquires(net_table)
void take_net(void) { pthread_mutex_lock(&a); }
void other(void) { }

// (1) RED: an indirect call with NO declared targets, made while holding a lock — the callee's lock
// behaviour is unknown, so a deadlock cannot be ruled out.
void call_opaque(void (*cb)(void)) {
  pthread_mutex_lock(&a);
  cb();                        //EXPECT UNDECLARED_INDIRECT_CALL
  pthread_mutex_unlock(&a);
}

// A function-pointer slot restricted to `take_disk`.
// @calls(take_disk)
static void (*hook)(void);

// (2) GREEN: the declared target takes disk while we hold net — the declared order (net < disk) is
// respected across the indirect call, so no deadlock.
void call_declared_ok(void) {
  pthread_mutex_lock(&a);
  hook();
  pthread_mutex_unlock(&a);
}

// A slot restricted to `take_net`.
// @calls(take_net)
static void (*hook2)(void);

// (3) RED: the declared target takes net while we hold disk — the reverse of the declared order, an
// AB-BA deadlock reached THROUGH the callback.
void call_declared_bad(void) {
  pthread_mutex_lock(&b);
  hook2();                     //EXPECT LOCK_ORDER_VIOLATION
  pthread_mutex_unlock(&b);
}

// (4) RED: assigning the slot a function OUTSIDE its declared set — the annotation-vs-implementation
// check (an indirect call through it could then reach an unverified function).
void wire_bad(void) {
  hook = other;                //EXPECT UNDECLARED_FN_TARGET
}

// (5) GREEN: assigning a declared target is clean.
void wire_ok(void) {
  hook = take_disk;
}
