// @threadsafe
// LOCK-BALANCE (the leak analogue for locks — concurrency axis v2). A lock ACQUIRED in a
// `@threadsafe` function but still HELD on an exit path is LOCK_LEAKED: the canonical
// `lock(); if(err) return; ...; unlock();` error-path deadlock. This is a MAY-analysis (a lock
// leaks if held on SOME path), the dual of the UNGUARDED_ACCESS MUST-pass. The escapes are
// VERIFIED declared contracts: `@acquires(l)` hands `l` to the caller held (and must be held on
// every exit, else LOCK_NOT_ACQUIRED); `@releases(l)` says the caller holds `l` at entry (it
// must be released before return). The same `pthread_mutex_lock/unlock` vocabulary as t134.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

typedef struct { pthread_mutex_t lock; int data; } counter;

// (1) GREEN: acquired and released on the single path.
int ok_balanced(counter *c) {
  pthread_mutex_lock(&c->lock);
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (2) RED: the early error return leaves the lock held — the classic deadlock-on-next-acquire.
int leak_early_return(counter *c, int err) {
  pthread_mutex_lock(&c->lock);
  if (err) {
    return -1;                         //EXPECT LOCK_LEAKED
  }
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (3) RED: never released — still held when control falls off the end.
void leak_fallthrough(counter *c) {
  pthread_mutex_lock(&c->lock);
  c->data++;
  return;                              //EXPECT LOCK_LEAKED
}

// (4) GREEN: released on BOTH branches before returning.
int ok_both_branches(counter *c, int cond) {
  pthread_mutex_lock(&c->lock);
  if (cond) {
    pthread_mutex_unlock(&c->lock);
    return 0;
  }
  pthread_mutex_unlock(&c->lock);
  return c->data;
}

// (5) GREEN: `@acquires` hands the lock to the caller held — an intentional hand-off, not a leak.
// @acquires(c->lock)
void lock_for_caller(counter *c) {
  pthread_mutex_lock(&c->lock);
}

// (6) RED: declares `@acquires` but acquires it on only one path — the caller cannot rely on it.
// @acquires(c->lock)
void lock_maybe(counter *c, int cond) {
  if (cond) {
    pthread_mutex_lock(&c->lock);
  }
  return;                              //EXPECT LOCK_NOT_ACQUIRED
}

// (7) GREEN: `@releases` — the caller holds it at entry, this function releases it.
// @releases(c->lock)
void release_for_caller(counter *c) {
  pthread_mutex_unlock(&c->lock);
}

// (8) RED: declares `@releases` but never releases — still held at exit.
// @releases(c->lock)
void forgot_release(counter *c) {
  c->data++;
  return;                              //EXPECT LOCK_LEAKED
}
