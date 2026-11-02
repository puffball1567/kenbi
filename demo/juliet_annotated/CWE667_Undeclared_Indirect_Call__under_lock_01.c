// @threadsafe
/* STATE B — a half-fix: the indirect call is now conditional, but the c-path still calls an
   undeclared-target pointer under the lock. STILL UNDECLARED_INDIRECT_CALL. Long header for
   file-level binding. padding line seven. */
/* CWE: 667 Improper Locking (indirect call with undeclared targets while holding a lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void CWE667_Undeclared_Indirect_Call__under_lock_01_bad(void (*cb)(void), int c) {
    pthread_mutex_lock(&g);
    if (c) cb();   /* POTENTIAL FLAW: undeclared target still called under the lock */
    pthread_mutex_unlock(&g);
}
