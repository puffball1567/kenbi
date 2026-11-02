// @threadsafe
/* STATE A — two mutexes with a declared order `@lock_order(A < B)`, but this function acquires
   them B-then-A: the classic AB-BA deadlock. kenbi default-reds it: LOCK_ORDER_VIOLATION.
   Progression: always-reversed -> one-path-reversed -> consistent order. */
/* CWE: 833 Deadlock (locks acquired in an order inconsistent with the declared @lock_order) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;
pthread_mutex_t B;
// @lock_order(A < B)

void CWE833_Deadlock__lock_order_02_bad(void)
{
    pthread_mutex_lock(&B);
    /* POTENTIAL FLAW: B-then-A reverses the declared A < B order */
    pthread_mutex_lock(&A);
    pthread_mutex_unlock(&A);
    pthread_mutex_unlock(&B);
}
