// @threadsafe
// CONCURRENCY (lock discipline) GATING. A field declared `@guarded_by(field: lock)` is a
// data race unless `lock` is PROVABLY held at the access — a MUST-analysis: the held-set is
// the intersection across branches (held only if held on every path). A recognised acquire
// (`pthread_mutex_lock(&m)`) / release toggles it. Default-red (UNGUARDED_ACCESS) when not
// provably held. Separate opt-in axis (`@threadsafe`), so non-concurrent files are never
// lock-checked. kenbi confirms a lock is demonstrably held; it never proves one unnecessary.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

typedef struct { pthread_mutex_t lock; int data; } counter;

// (1) GREEN: read while the lock is held.
// @guarded_by(c->data: c->lock)
int read_locked(counter *c) {
  pthread_mutex_lock(&c->lock);
  int v = c->data;                     // c->lock held — ok
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (2) GREEN: write while the lock is held (writes are guarded too).
// @guarded_by(c->data: c->lock)
void write_locked(counter *c, int v) {
  pthread_mutex_lock(&c->lock);
  c->data = v;                         // held — ok
  pthread_mutex_unlock(&c->lock);
}

// (3) RED: access with no lock held.
// @guarded_by(c->data: c->lock)
int read_unlocked(counter *c) {
  return c->data;                      //EXPECT UNGUARDED_ACCESS
}

// (4) RED: access AFTER the lock is released.
// @guarded_by(c->data: c->lock)
int read_after_release(counter *c) {
  pthread_mutex_lock(&c->lock);
  pthread_mutex_unlock(&c->lock);
  return c->data;                      //EXPECT UNGUARDED_ACCESS
}

// (5) RED: the lock is held on only ONE branch — not provably held at the join. (It is
// released within the branch so this isolates UNGUARDED_ACCESS; the lock-balance pass — a
// separate axis — owns the held-at-exit / leak case, see t140.)
// @guarded_by(c->data: c->lock)
int read_one_branch(counter *c, int cond) {
  if (cond) {
    pthread_mutex_lock(&c->lock);
    pthread_mutex_unlock(&c->lock);
  }
  return c->data;                      //EXPECT UNGUARDED_ACCESS
}
