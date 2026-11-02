// @threadsafe
// DEADLOCK FREEDOM (concurrency v2) — guarantees Rust does NOT make. Rust's borrow checker
// prevents data races, but a `Mutex::lock()` while already holding the lock just HANGS at
// runtime, and acquiring two mutexes in inconsistent orders (AB-BA) is a runtime deadlock Rust
// cannot catch. kenbi refuses both statically (default-red, opt-in `@threadsafe`):
//   * DOUBLE_LOCK            — re-acquiring a held lock (self-deadlock on a non-recursive mutex).
//   * LOCK_ORDER_VIOLATION   — acquiring locks in the reverse of a declared `@lock_order`.
//   * UNLOCK_WITHOUT_LOCK    — releasing a lock not provably held (UB / double-unlock).
// Same pthread vocabulary as t134/t140; the locks here are globals.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

pthread_mutex_t A;
pthread_mutex_t B;

// @lock_order(A < B)   //EXPECT LOCK_ORDER

// (1) RED: re-acquiring A self-deadlocks a non-recursive mutex.
void self_deadlock(void) {
  pthread_mutex_lock(&A);
  pthread_mutex_lock(&A);              //EXPECT DOUBLE_LOCK
  pthread_mutex_unlock(&A);
}

// (2) GREEN: a single balanced acquire / release.
void ok_single(void) {
  pthread_mutex_lock(&A);
  pthread_mutex_unlock(&A);
}

// (3) RED: B then A is the reverse of `@lock_order(A < B)` — the classic AB-BA deadlock.
void ab_ba(void) {
  pthread_mutex_lock(&B);
  pthread_mutex_lock(&A);              //EXPECT LOCK_ORDER_VIOLATION
  pthread_mutex_unlock(&A);
  pthread_mutex_unlock(&B);
}

// (4) GREEN: A then B respects the declared order.
void ab_ok(void) {
  pthread_mutex_lock(&A);
  pthread_mutex_lock(&B);
  pthread_mutex_unlock(&B);
  pthread_mutex_unlock(&A);
}

// (5) RED: releasing a lock that was never held.
void bad_unlock(void) {
  pthread_mutex_unlock(&A);            //EXPECT UNLOCK_WITHOUT_LOCK
}

// (6) RED: double-unlock — the second release has nothing held.
void double_unlock(void) {
  pthread_mutex_lock(&A);
  pthread_mutex_unlock(&A);
  pthread_mutex_unlock(&A);            //EXPECT UNLOCK_WITHOUT_LOCK
}
