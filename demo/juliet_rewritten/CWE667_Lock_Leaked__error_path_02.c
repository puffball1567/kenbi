// @threadsafe
/* STATE C — the lock is released on EVERY exit, including the early error path. GREEN. Header kept
   long enough for file-level @threadsafe binding. padding six. padding seven. */
/* CWE: 667 Improper Locking — fixed by releasing on all paths. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
int CWE667_Lock_Leaked__error_path_02_fixed(counter *c, int err) {
    pthread_mutex_lock(&c->lock);
    if (err) { pthread_mutex_unlock(&c->lock); return -1; }
    int v = c->data;
    pthread_mutex_unlock(&c->lock);
    return v;
}
