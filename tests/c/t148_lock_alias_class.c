// @threadsafe
// CONCURRENCY v3 STAGE 2 — checked pointer-alias lock IDENTITY. Stage 1 (`@lock_class`) pinned the
// identity of a DIRECTLY-named lock (`lock(&a)`). But locks are routinely taken through a pointer
// (`pthread_mutex_t *p = &a; lock(p);`). Stage 2 lets such a pointer JOIN the lock's class, so the
// order / double-lock checks see THROUGH the pointer. The alias is CHECKED, not trusted: a pointer
// joins a class only if EVERY write to it is `&<classed-lock>` of the SAME class and its address is
// never taken — an unambiguous single-class definition ("p is class X because p = &a", falsifiable).
// A pointer written two different classes, a non-classed value, or whose address escapes falls back
// to USR keying (conservative — never a false GREEN). Identity through pointers is the load-bearing
// key for cross-function / aliased lock order.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

static pthread_mutex_t a;   // @lock_class(net_table)
static pthread_mutex_t b;   // @lock_class(disk_table)

// (1) GREEN: a lock taken and released through a pointer alias — `p` is net_table on both, balanced.
// No false LOCK_LEAKED / UNLOCK_WITHOUT_LOCK from the indirection.
void via_ptr_clean(void) {
  pthread_mutex_t *p = &a;
  pthread_mutex_lock(p);
  pthread_mutex_unlock(p);
}

// (2) RED: AB-BA through pointer aliases. `p`=net_table, `q`=disk_table; locking q-then-p is the
// reverse of the declared order — caught BY CLASS even though both acquires go through pointers.
// @lock_order(net_table < disk_table)   //EXPECT LOCK_ORDER
void via_ptr_abba(void) {
  pthread_mutex_t *p = &a;
  pthread_mutex_t *q = &b;
  pthread_mutex_lock(q);
  pthread_mutex_lock(p);                 //EXPECT LOCK_ORDER_VIOLATION
  pthread_mutex_unlock(p);
  pthread_mutex_unlock(q);
}

// (3) RED: a pointer alias and a DIRECT acquire are the SAME lock (same class) — the double-lock is
// seen across the alias (`lock(&a)` then `lock(p)` where `p = &a` = self-deadlock).
void via_ptr_double(void) {
  pthread_mutex_t *p = &a;
  pthread_mutex_lock(&a);
  pthread_mutex_lock(p);                 //EXPECT DOUBLE_LOCK
  pthread_mutex_unlock(p);
}
