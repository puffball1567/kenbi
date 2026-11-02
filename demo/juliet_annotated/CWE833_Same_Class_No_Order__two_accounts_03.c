// @threadsafe
/* STATE B — a half-fix: an ordering guard is present but BACKWARDS (in the a<b branch it locks the
   HIGHER-addressed b first), defeating the discipline. kenbi checks the DIRECTION, so it is STILL
   SAME_CLASS_NO_ORDER. Long header for file-level binding. padding line seven. */
/* CWE: 833 Deadlock (two same-class locks with no canonical order) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct account { pthread_mutex_t lock;   // @lock_class(account_lock)
                         int balance; } account;
void CWE833_Same_Class_No_Order__two_accounts_03_bad(account *a, account *b, int amt) {
    if (a < b) { pthread_mutex_lock(&b->lock); pthread_mutex_lock(&a->lock); }
    else       { pthread_mutex_lock(&a->lock); pthread_mutex_lock(&b->lock); }
    pthread_mutex_unlock(&a->lock);
    pthread_mutex_unlock(&b->lock);
}
