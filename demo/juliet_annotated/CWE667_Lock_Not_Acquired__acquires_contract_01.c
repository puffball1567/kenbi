// @threadsafe
/* STATE B — a half-fix: the lock is acquired on ONE branch only, so an exit path returns without
   it held — the @acquires contract is not established on every path. STILL LOCK_NOT_ACQUIRED.
   Long header for file-level binding. padding line seven. */
/* CWE: 667 Improper Locking (@acquires contract not established on all exits) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
// @acquires(c->lock)
void CWE667_Lock_Not_Acquired__acquires_contract_01_bad(counter *c, int cond) {
    if (cond) { pthread_mutex_lock(&c->lock); }   /* POTENTIAL FLAW: else path holds nothing */
}
