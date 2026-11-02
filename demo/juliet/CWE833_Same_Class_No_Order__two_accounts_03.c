// @threadsafe
/* STATE A — two DISTINCT instances of one @lock_class are held at once with NO canonical order —
   the classic AB-BA deadlock (thread 1 transfer(x,y), thread 2 transfer(y,x)). kenbi flags
   SAME_CLASS_NO_ORDER. Progression: no-order -> wrong-order -> canonical address order. Long
   header for file-level binding. */
/* CWE: 833 Deadlock (two same-class locks with no canonical order) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct account { pthread_mutex_t lock;   // @lock_class(account_lock)
                         int balance; } account;
void CWE833_Same_Class_No_Order__two_accounts_03_bad(account *a, account *b, int amt) {
    pthread_mutex_lock(&a->lock);
    pthread_mutex_lock(&b->lock);   /* POTENTIAL FLAW: two same-class instances, no order */
    a->balance -= amt; b->balance += amt;
    pthread_mutex_unlock(&b->lock);
    pthread_mutex_unlock(&a->lock);
}
