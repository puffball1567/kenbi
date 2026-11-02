// @threadsafe
/* STATE A — the address of a @guarded_by field ESCAPES into an alias; a later write through it
   races after the lock is dropped — invisible to the held-set check. kenbi flags GUARDED_ESCAPE
   at the address-taking (unconditional: holding the lock cannot protect later aliased uses).
   Progression: alias-escape -> callee-escape -> inline access. Long header for file-level binding. */
/* CWE: 362 Race Condition (address of a guarded field escapes) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
extern void sink(int *q);
typedef struct {
  pthread_mutex_t lock;
  int data;            // @guarded_by(lock)
} counter;
void CWE362_Guarded_Escape__address_of_field_02_bad(counter *c) {
    pthread_mutex_lock(&c->lock);
    int *p = &c->data;   /* POTENTIAL FLAW: address of the guarded field escapes */
    pthread_mutex_unlock(&c->lock);
    *p = 5;
}
