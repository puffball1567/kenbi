// @threadsafe
/* STATE C — the lock is acquired on every path, so it is provably held at return, honouring
   @acquires. GREEN. Long header for file-level binding. padding six. padding seven. */
/* CWE: 667 Improper Locking — fixed by acquiring on all paths. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
// @acquires(c->lock)
void CWE667_Lock_Not_Acquired__acquires_contract_01_fixed(counter *c) {
    pthread_mutex_lock(&c->lock);
}
