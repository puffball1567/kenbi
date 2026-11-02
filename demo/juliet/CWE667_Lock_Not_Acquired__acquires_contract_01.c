// @threadsafe
/* STATE A — the function declares @acquires(c->lock): it promises to hand the lock to the caller
   HELD. But the body never acquires it, so the caller's assumption is false. kenbi flags
   LOCK_NOT_ACQUIRED. Progression: never-acquires -> one-path -> every-path. Long header for
   file-level binding. */
/* CWE: 667 Improper Locking (@acquires contract not established on all exits) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;
// @acquires(c->lock)
void CWE667_Lock_Not_Acquired__acquires_contract_01_bad(counter *c) {
    (void)c;   /* POTENTIAL FLAW: promised @acquires but never locks */
}
