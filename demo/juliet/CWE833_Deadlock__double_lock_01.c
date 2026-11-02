// @threadsafe
/* STATE A — adopted for lock checking. The same non-recursive mutex is acquired TWICE without an
   intervening release, which self-deadlocks. kenbi default-reds it: DOUBLE_LOCK. Progression:
   unconditional -> conditional double-lock -> single balanced lock. */
/* CWE: 833 Deadlock (re-acquiring a held lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;

void CWE833_Deadlock__double_lock_01_bad(void)
{
    pthread_mutex_lock(&A);
    /* POTENTIAL FLAW: re-acquiring A self-deadlocks */
    pthread_mutex_lock(&A);
    pthread_mutex_unlock(&A);
}
