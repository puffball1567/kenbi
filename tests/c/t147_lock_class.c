// @threadsafe
// CONCURRENCY v3 — checked lock IDENTITY via `@lock_class(X)`. The cross-function order for GLOBAL
// locks was blocked by identity: a global's direct acquire keys by USR, but the call-site contract
// could not, and two `static pthread_mutex_t lock;` in different files share a display (keying by
// display would conflate them). The fix is declare-don't-infer applied to identity: `@lock_class(X)`
// on the lock DECLARATION names its class; every acquire and every contract (`@acquires(X)`,
// `@lock_order(X < Y)`) keys by the author's class string X. CHECKED, not trusted: the var<->class
// mapping is DERIVED from the decl (resolveLockClasses), so it is structural. Distinct class names
// dissolve the static same-name collision. With identity pinned, cross-function AB-BA on globals
// falls out of the existing LOCK_ORDER_VIOLATION.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

// Two global locks given identity classes.
static pthread_mutex_t a;   // @lock_class(net_table)
static pthread_mutex_t b;   // @lock_class(disk_table)

// Helpers that acquire / release by CLASS name (verified @acquires/@releases in @threadsafe scope).
// @acquires(net_table)
void lock_net(void) { pthread_mutex_lock(&a); }
// @releases(net_table)
void unlock_net(void) { pthread_mutex_unlock(&a); }
// @acquires(disk_table)
void lock_disk(void) { pthread_mutex_lock(&b); }
// @releases(disk_table)
void unlock_disk(void) { pthread_mutex_unlock(&b); }

// (1) GREEN: net then disk via helpers — the declared order is respected across the calls.
// @lock_order(net_table < disk_table)   //EXPECT LOCK_ORDER
void good(void) {
  lock_net();
  lock_disk();
  unlock_disk();
  unlock_net();
}

// (2) RED: disk then net via helpers — the reverse of the declared order, a cross-function AB-BA
// deadlock on GLOBAL locks, identified by class.
// @lock_order(net_table < disk_table)   //EXPECT LOCK_ORDER
void bad(void) {
  lock_disk();
  lock_net();                            //EXPECT LOCK_ORDER_VIOLATION
  unlock_net();
  unlock_disk();
}
