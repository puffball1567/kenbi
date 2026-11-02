// @threadsafe
/* STATE C — the slot is only ever assigned a DECLARED target (safe_cb), matching @calls. GREEN.
   Long header for file-level binding. padding six. padding seven. */
/* CWE: 667 Improper Locking — fixed by assigning only declared targets. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void safe_cb(void) { }
void other_fn(void) { }
// @calls(safe_cb)
static void (*hook)(void);
void CWE667_Undeclared_Fn_Target__wrong_assignment_01_fixed(void) {
    hook = safe_cb;   /* declared target */
}
