// @threadsafe
/* STATE B — a half-fix: one branch respects A < B, but the else branch still acquires B-then-A,
   so a deadlocking interleaving remains. STILL LOCK_ORDER_VIOLATION — every path must respect the
   order. */
/* CWE: 833 Deadlock (locks acquired inconsistently with the declared @lock_order) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;
pthread_mutex_t B;
// @lock_order(A < B)

void CWE833_Deadlock__lock_order_02_bad(int c)
{
    if (c) {
        pthread_mutex_lock(&A);
        pthread_mutex_lock(&B);
        pthread_mutex_unlock(&B);
        pthread_mutex_unlock(&A);
    } else {
        pthread_mutex_lock(&B);
        /* POTENTIAL FLAW: the else path still reverses the order */
        pthread_mutex_lock(&A);
        pthread_mutex_unlock(&A);
        pthread_mutex_unlock(&B);
    }
}
