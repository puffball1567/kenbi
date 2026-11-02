// @threadsafe
/* STATE B — a half-fix: the slot is assigned the declared target on one branch but the UNDECLARED
   other_fn on the other. STILL UNDECLARED_FN_TARGET on that path. Long header for file-level
   binding. padding line seven. */
/* CWE: 667 Improper Locking (function pointer assigned an undeclared target) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void safe_cb(void) { }
void other_fn(void) { }
// @calls(safe_cb)
static void (*hook)(void);
void CWE667_Undeclared_Fn_Target__wrong_assignment_01_bad(int c) {
    if (c) hook = safe_cb;
    else   hook = other_fn;   /* POTENTIAL FLAW: undeclared target on the else path */
}
