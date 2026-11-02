// @threadsafe
/* STATE C — the callable target is DECLARED with @calls; kenbi resolves it and verifies its lock
   behaviour (safe_cb takes no lock), so the indirect call under the lock is safe. GREEN. Long
   header for file-level binding. padding seven. */
/* CWE: 667 Improper Locking — fixed by declaring the callable targets. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void safe_cb(void) { }
// @calls(safe_cb)
static void (*hook)(void);
void CWE667_Undeclared_Indirect_Call__under_lock_01_fixed(void) {
    pthread_mutex_lock(&g);
    hook();   /* declared target safe_cb takes no lock -> no deadlock */
    pthread_mutex_unlock(&g);
}
