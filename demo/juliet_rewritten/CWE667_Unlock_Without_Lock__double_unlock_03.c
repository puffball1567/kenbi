// @threadsafe
/* STATE C — a single balanced acquire / release; every unlock matches a held lock. GREEN. Header
   kept long enough for file-level binding. padding six. padding seven. */
/* CWE: 667 Improper Locking — fixed by a balanced acquire/release. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
void CWE667_Unlock_Without_Lock__double_unlock_03_fixed(counter *c) {
    pthread_mutex_lock(&c->lock);
    c->data++;
    pthread_mutex_unlock(&c->lock);
}
