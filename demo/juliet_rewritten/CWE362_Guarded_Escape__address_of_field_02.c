// @threadsafe
/* STATE C — the guarded field is accessed INLINE under the lock; no address is taken, so every use
   is verifiable. GREEN. Long header for file-level binding. padding six. padding seven. */
/* CWE: 362 Race Condition — fixed by keeping the access inline under the lock. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
extern void sink(int *q);
typedef struct {
  pthread_mutex_t lock;
  int data;            // @guarded_by(lock)
} counter;
int CWE362_Guarded_Escape__address_of_field_02_fixed(counter *c) {
    pthread_mutex_lock(&c->lock);
    int v = c->data;
    pthread_mutex_unlock(&c->lock);
    return v;
}
