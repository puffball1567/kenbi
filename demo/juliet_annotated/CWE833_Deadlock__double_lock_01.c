// @threadsafe
/* STATE B — a half-fix that still self-deadlocks: the second acquire is guarded by a condition,
   but on the c-path A is acquired while already held. The held-set is a MUST-property, so it is
   STILL DOUBLE_LOCK on that path. */
/* CWE: 833 Deadlock (re-acquiring a held lock) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
pthread_mutex_t A;

void CWE833_Deadlock__double_lock_01_bad(int c)
{
    pthread_mutex_lock(&A);
    /* POTENTIAL FLAW: on the c-path A is acquired while already held */
    if (c) { pthread_mutex_lock(&A); }
    pthread_mutex_unlock(&A);
}
