// @threadsafe
/* STATE B — a half-fix: the address is passed to a callee instead of a local alias, but it still
   escapes — kenbi cannot verify the callee keeps it guarded. STILL GUARDED_ESCAPE. Long header for
   file-level binding. padding line seven. */
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
    sink(&c->data);   /* POTENTIAL FLAW: the guarded field's address escapes to a callee */
    pthread_mutex_unlock(&c->lock);
}
