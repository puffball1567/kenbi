// @threadsafe
/* STATE A — adopted; a lock is released with nothing held on the path — a double-unlock / UB.
   kenbi flags UNLOCK_WITHOUT_LOCK. Progression: unlock-unheld -> double-unlock -> balanced. Header
   kept long enough for file-level binding. padding seven. */
/* CWE: 667 Improper Locking (release of a lock that is not held) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
void CWE667_Unlock_Without_Lock__double_unlock_03_bad(counter *c) {
    pthread_mutex_unlock(&c->lock);   /* POTENTIAL FLAW: nothing is held */
}
