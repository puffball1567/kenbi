// @threadsafe
/* STATE C — a canonical ADDRESS order: the lower-addressed instance is locked first on BOTH
   branches, so no thread pair can acquire them in opposite orders. GREEN. Long header for
   file-level binding. padding seven. */
/* CWE: 833 Deadlock — fixed by a canonical lock order. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct account { pthread_mutex_t lock;   // @lock_class(account_lock)
                         int balance; } account;
void CWE833_Same_Class_No_Order__two_accounts_03_fixed(account *a, account *b, int amt) {
    if (a < b) { pthread_mutex_lock(&a->lock); pthread_mutex_lock(&b->lock); }
    else       { pthread_mutex_lock(&b->lock); pthread_mutex_lock(&a->lock); }
    a->balance -= amt; b->balance += amt;
    pthread_mutex_unlock(&a->lock);
    pthread_mutex_unlock(&b->lock);
}
