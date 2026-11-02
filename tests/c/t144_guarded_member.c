// @threadsafe
// CONCURRENCY v2 — single-arg `@guarded_by(lock)` on a STRUCT MEMBER (the enclosing-struct bind).
// The natural idiom: annotate the data field at its declaration, naming a SIBLING lock field by
// simple name. kenbi binds it per TYPE (the field's declaration USR), so an access `base->data`
// requires `base->lock` (the same instance's sibling) held — the per-instance version of the
// two-arg `@guarded_by(field: lock)`. Gates (UNGUARDED_ACCESS) only in a `@threadsafe` scope;
// otherwise advisory. Uses the same held-set as t134/t143, so it composes with lock() and trylock.
// Padding lines keep the file-level @threadsafe marker from binding to an extern decl below.
// padding
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
extern int pthread_mutex_trylock(pthread_mutex_t *m);

typedef struct {
  pthread_mutex_t lock;
  int data;            // @guarded_by(lock)
} counter;

// (1) GREEN: the sibling lock is held across the access.
int read_locked(counter *c) {
  pthread_mutex_lock(&c->lock);
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (2) GREEN: write while held (writes are guarded too).
void write_locked(counter *c, int v) {
  pthread_mutex_lock(&c->lock);
  c->data = v;
  pthread_mutex_unlock(&c->lock);
}

// (3) RED: no lock held.
int read_unlocked(counter *c) {
  return c->data;                      //EXPECT UNGUARDED_ACCESS
}

// (4) RED: a DIFFERENT instance's lock — `d->lock` does not guard `c->data` (per-instance keys).
int read_wrong_instance(counter *c, counter *d) {
  pthread_mutex_lock(&d->lock);
  int v = c->data;                     //EXPECT UNGUARDED_ACCESS
  pthread_mutex_unlock(&d->lock);
  return v;
}

// (5) GREEN: composes with trylock — the sibling lock is held on the success branch.
int read_trylocked(counter *c) {
  if (pthread_mutex_trylock(&c->lock) == 0) {
    int v = c->data;
    pthread_mutex_unlock(&c->lock);
    return v;
  }
  return -1;
}

// (6) RED: access after releasing the lock.
int read_after_release(counter *c) {
  pthread_mutex_lock(&c->lock);
  pthread_mutex_unlock(&c->lock);
  return c->data;                      //EXPECT UNGUARDED_ACCESS
}
