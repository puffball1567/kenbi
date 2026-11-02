// @threadsafe
/* STATE B — a half-fix: the lock is released on the normal path, but an early error return still
   leaves it HELD. A lock leaks if held on SOME path, so it is STILL LOCK_LEAKED. Header kept long
   enough for file-level @threadsafe binding. padding line seven. */
/* CWE: 667 Improper Locking (lock held on an exit path) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
int CWE667_Lock_Leaked__error_path_02_bad(counter *c, int err) {
    pthread_mutex_lock(&c->lock);
    if (err) return -1;   /* POTENTIAL FLAW: early return still holds the lock */
    int v = c->data;
    pthread_mutex_unlock(&c->lock);
    return v;
}
