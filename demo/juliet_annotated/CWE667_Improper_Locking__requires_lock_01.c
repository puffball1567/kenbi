// @threadsafe
/* STATE B — a half-fix: g_lock is acquired but RELEASED before the call, so the callee's
   precondition is not met at the call site. STILL REQUIRED_LOCK_NOT_HELD. */
/* CWE: 667 Improper Locking (calling a @requires_lock function without the lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t g_lock;
// @requires_lock(g_lock)
void touch_shared(void);

void CWE667_Improper_Locking__requires_lock_01_bad(void)
{
    pthread_mutex_lock(&g_lock);
    pthread_mutex_unlock(&g_lock);
    /* POTENTIAL FLAW: released before the call */
    touch_shared();
}
