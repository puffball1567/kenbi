// @threadsafe
/* STATE C — the lock is acquired and released in a single balanced pair, never re-acquired while
   held. No self-deadlock. GREEN. */
/* CWE: 833 Deadlock — fixed by a single balanced acquire/release. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;

void CWE833_Deadlock__double_lock_01_fixed(void)
{
    pthread_mutex_lock(&A);
    pthread_mutex_unlock(&A);   /* FIXED: balanced single lock */
}
