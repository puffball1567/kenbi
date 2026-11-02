// @threadsafe
// CONCURRENCY v2 — CROSS-FUNCTION lock order. A callee declared `@acquires(C)` leaves C held in
// the caller after the call; `@releases(C)` requires C held and drops it. Wiring those verified
// contracts into the caller's held-set at the call site makes the existing within-function
// LOCK_ORDER_VIOLATION check span the call boundary — so an AB-BA deadlock formed THROUGH helper
// functions is caught, with no new check and no new annotation (reuses @acquires/@releases +
// @lock_order). `param->field` locks resolve to the same key a direct acquire uses (struct-based
// locking); globals are a follow-up (their direct acquire keys by USR — a separate unification).
// Padding keeps the file-level @threadsafe marker off the extern decls below.
// padding
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct node { pthread_mutex_t lock; int v; } node;

// A lock-acquiring helper: hands the lock back to the caller held (verified @acquires contract).
// @acquires(n->lock)
void lock_node(node *n) { pthread_mutex_lock(&n->lock); }

// A lock-releasing helper: the caller holds it at entry, this drops it (verified @releases).
// @releases(n->lock)
void unlock_node(node *n) { pthread_mutex_unlock(&n->lock); }

// (1) GREEN: parent then child via helpers — the declared order is respected across the calls.
// @lock_order(parent->lock < child->lock)   //EXPECT LOCK_ORDER
void good(node *parent, node *child) {
  lock_node(parent);
  lock_node(child);
  unlock_node(child);
  unlock_node(parent);
}

// (2) RED: child then parent via helpers — the reverse of the declared order, a cross-function
// AB-BA deadlock. The violation is reported at the call that acquires the out-of-order lock.
// @lock_order(parent->lock < child->lock)   //EXPECT LOCK_ORDER
void bad(node *parent, node *child) {
  lock_node(child);
  lock_node(parent);                   //EXPECT LOCK_ORDER_VIOLATION
  unlock_node(parent);
  unlock_node(child);
}
