// @threadsafe
// REQUIRES_LOCK — a cross-function lock PRECONDITION (concurrency v2). A callee declared
// `@requires_lock(m)` may only be called with `m` held; the lock-balance pass checks the
// caller's held-set at every call site (MUST: held on every path) and refuses a call without
// it — REQUIRED_LOCK_NOT_HELD (default-red, a data race on state the callee assumes is locked).
// This is the held-state analogue of `@frees`: the contract lives on the callee, verified at
// the caller. Display matching is exact for global / file-scope locks (the common "hold the big
// lock before calling this" precondition). Same pthread vocabulary as t134/t140/t141.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

pthread_mutex_t g_lock;

// The callee: callers must already hold g_lock. (A bare prototype keeps its reviewer advisory.)
// @requires_lock(g_lock)   //EXPECT REQUIRES_LOCK
void touch_shared(void);

// (1) GREEN: the caller holds g_lock across the call.
void ok_caller(void) {
  pthread_mutex_lock(&g_lock);
  touch_shared();
  pthread_mutex_unlock(&g_lock);
}

// (2) RED: the caller never acquires g_lock.
void bad_caller(void) {
  touch_shared();                     //EXPECT REQUIRED_LOCK_NOT_HELD
}

// (3) RED: g_lock was released before the call.
void bad_after_release(void) {
  pthread_mutex_lock(&g_lock);
  pthread_mutex_unlock(&g_lock);
  touch_shared();                     //EXPECT REQUIRED_LOCK_NOT_HELD
}

// (4) Mixed: held on the locked branch (ok), absent on the other (red).
void split_caller(int c) {
  if (c) {
    pthread_mutex_lock(&g_lock);
    touch_shared();
    pthread_mutex_unlock(&g_lock);
  } else {
    touch_shared();                   //EXPECT REQUIRED_LOCK_NOT_HELD
  }
}

// ---- struct-field locks (modern-C `struct conn { pthread_mutex_t lock; ... }`): the precondition
// names a lock reached through the callee's parameter; it resolves through each call's argument.
typedef struct { pthread_mutex_t lock; int data; } conn;

// @requires_lock(s->lock)   //EXPECT REQUIRES_LOCK
void conn_touch(conn *s);

// (5) GREEN: the caller holds x->lock — resolved through the argument to the same key.
void ok_field(conn *x) {
  pthread_mutex_lock(&x->lock);
  conn_touch(x);
  pthread_mutex_unlock(&x->lock);
}

// (6) RED: the caller passes x but never holds x->lock.
void bad_field(conn *x) {
  conn_touch(x);                      //EXPECT REQUIRED_LOCK_NOT_HELD
}
