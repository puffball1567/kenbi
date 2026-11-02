// @threadsafe
/* STATE A — `touch_shared` declares `@requires_lock(g_lock)`: callers must already hold g_lock.
   This caller never acquires it. kenbi default-reds the precondition violation:
   REQUIRED_LOCK_NOT_HELD. Progression: no-lock -> released-too-early -> held-across-call. */
/* CWE: 667 Improper Locking (calling a @requires_lock function without the lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t g_lock;
// @requires_lock(g_lock)
void touch_shared(void);

void CWE667_Improper_Locking__requires_lock_01_bad(void)
{
    /* POTENTIAL FLAW: g_lock is never held here */
    touch_shared();
}
