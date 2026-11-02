// @threadsafe
/* STATE C — the locks are always acquired A-then-B, consistent with `@lock_order(A < B)` on every
   path. No AB-BA cycle. GREEN. */
/* CWE: 833 Deadlock — fixed by acquiring in the declared order. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;
pthread_mutex_t B;
// @lock_order(A < B)

void CWE833_Deadlock__lock_order_02_fixed(void)
{
    pthread_mutex_lock(&A);
    pthread_mutex_lock(&B);
    pthread_mutex_unlock(&B);
    pthread_mutex_unlock(&A);
}
