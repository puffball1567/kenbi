// @threadsafe
// CONCURRENCY v2 — trylock as a CONDITIONAL acquire. `pthread_mutex_trylock(&m)` returns 0
// (success: the lock is HELD) or nonzero (failure: NOT held), so the lock is held only on the
// SUCCESS branch. kenbi recognises this from the enclosing `if` condition (never as an
// unconditional acquire) and adds the lock to the held-set of the success branch only — the same
// branch-fact machinery as null narrowing. Forms (success/held branch in parens):
//   `trylock()==0` / `!trylock()`  (THEN)   ·   `trylock()!=0` / bare `if(trylock())`  (ELSE).
// Both the UNGUARDED_ACCESS (MUST) pass and the lock-balance (MAY/MUST) pass consume it.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_trylock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

typedef struct { pthread_mutex_t lock; int data; } counter;

// (1) GREEN: a `@guarded_by` field read inside the trylock SUCCESS branch — the lock is held there.
// @guarded_by(c->data: c->lock)
int read_trylocked(counter *c) {
  if (pthread_mutex_trylock(&c->lock) == 0) {
    int v = c->data;                     // c->lock held on this branch — ok
    pthread_mutex_unlock(&c->lock);
    return v;
  }
  return -1;                             // failure branch: no access, ok
}

// (2) RED: the access is AFTER the if — the lock is held only on success, so at the join it is
// not provably held (intersection drops it). UNGUARDED_ACCESS, a data race.
// @guarded_by(c->data: c->lock)
int read_after_trylock(counter *c) {
  if (pthread_mutex_trylock(&c->lock) == 0) {
    pthread_mutex_unlock(&c->lock);
  }
  return c->data;                        //EXPECT UNGUARDED_ACCESS
}

// (3) RED: trylock succeeded but the lock is never released on the success branch — still held
// when control falls through to the return. LOCK_LEAKED (the leak analogue, MAY-analysis).
void trylock_leak(counter *c) {
  if (pthread_mutex_trylock(&c->lock) == 0) {
    c->data++;
    // forgot unlock
  }
  return;                                //EXPECT LOCK_LEAKED
}

// (4) GREEN: the `!= 0` early-return idiom — failure returns, the fall-through HOLDS the lock and
// releases it. Success is the ELSE / fall-through branch.
int trylock_early_return(counter *c) {
  if (pthread_mutex_trylock(&c->lock) != 0) {
    return -1;                           // failure: lock not held, clean return
  }
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (5) GREEN: bare `if (trylock(&m))` — nonzero (truthy) is failure, so the success holds on the
// ELSE / fall-through. Same as (4) without the explicit `!= 0`.
int trylock_bare(counter *c) {
  if (pthread_mutex_trylock(&c->lock)) {
    return -1;                           // failure path
  }
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (6) RED: the lock is held only on success (conditional), so unlocking it unconditionally after
// the if is not provably held on every path — UNLOCK_WITHOUT_LOCK (MUST). Proves trylock is NOT
// an unconditional acquire.
void trylock_bad_unlock(counter *c) {
  if (pthread_mutex_trylock(&c->lock) == 0) {
  }
  pthread_mutex_unlock(&c->lock);        //EXPECT UNLOCK_WITHOUT_LOCK
}
