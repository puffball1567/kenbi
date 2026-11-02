// @threadsafe
/* STATE A — an indirect call through a function pointer with NO declared targets is made while
   HOLDING a lock: the callee's lock behaviour is unknown, so a deadlock cannot be ruled out. kenbi
   flags UNDECLARED_INDIRECT_CALL. Progression: undeclared -> still undeclared -> declared targets.
   Long header for file-level binding. */
/* CWE: 667 Improper Locking (indirect call with undeclared targets while holding a lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void CWE667_Undeclared_Indirect_Call__under_lock_01_bad(void (*cb)(void)) {
    pthread_mutex_lock(&g);
    cb();   /* POTENTIAL FLAW: unknown callee lock behaviour under the lock */
    pthread_mutex_unlock(&g);
}
