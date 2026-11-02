// @threadsafe
/* STATE A — a function-pointer slot declared @calls(safe_cb) is ASSIGNED a function NOT in its
   declared target set (other_fn) — an annotation-vs-implementation mismatch kenbi refuses:
   UNDECLARED_FN_TARGET. Progression: wrong-target -> branch-wrong -> only-declared. Long header
   for file-level binding. */
/* CWE: 667 Improper Locking (function pointer assigned an undeclared target) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
static pthread_mutex_t g;
void safe_cb(void) { }
void other_fn(void) { }
// @calls(safe_cb)
static void (*hook)(void);
void CWE667_Undeclared_Fn_Target__wrong_assignment_01_bad(void) {
    hook = other_fn;   /* POTENTIAL FLAW: other_fn is not in @calls(safe_cb) */
}
