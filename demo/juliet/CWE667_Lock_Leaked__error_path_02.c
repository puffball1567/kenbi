// @threadsafe
/* STATE A — adopted; a lock is acquired but the function returns still HOLDING it (the canonical
   error-path deadlock-on-next-acquire). kenbi flags LOCK_LEAKED. Progression: never-released ->
   released-on-one-path -> released-on-all. This header is kept long enough for file-level binding. */
/* CWE: 667 Improper Locking (lock held on an exit path) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
int CWE667_Lock_Leaked__error_path_02_bad(counter *c) {
    pthread_mutex_lock(&c->lock);
    return c->data;   /* POTENTIAL FLAW: returns holding the lock */
}
