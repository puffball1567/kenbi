// @threadsafe
/* STATE B — a half-fix: the lock IS taken and released, but then released AGAIN — the second
   unlock has nothing held. STILL UNLOCK_WITHOUT_LOCK. Header kept long enough for file-level
   binding. padding line seven. */
/* CWE: 667 Improper Locking (release of a lock that is not held) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
void CWE667_Unlock_Without_Lock__double_unlock_03_bad(counter *c) {
    pthread_mutex_lock(&c->lock);
    pthread_mutex_unlock(&c->lock);
    pthread_mutex_unlock(&c->lock);   /* POTENTIAL FLAW: second unlock, nothing held */
}
