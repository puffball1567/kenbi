// @threadsafe
/* STATE C — g_lock is held ACROSS the call, meeting the callee's declared precondition. GREEN. */
/* CWE: 667 Improper Locking — fixed by holding the required lock across the call. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t g_lock;
// @requires_lock(g_lock)
void touch_shared(void);

void CWE667_Improper_Locking__requires_lock_01_fixed(void)
{
    pthread_mutex_lock(&g_lock);
    touch_shared();                 /* FIXED: held across the call */
    pthread_mutex_unlock(&g_lock);
}
