// @threadsafe
/* STATE A — adopted for lock checking (@threadsafe) with `c->data` declared @guarded_by its
   lock, but the field is read with NO lock held. kenbi default-reds the data race:
   UNGUARDED_ACCESS. Progression: no-lock -> released-too-early -> held. */
/* CWE: 362 Race Condition (unsynchronised access to a guarded field) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;

// @guarded_by(c->data: c->lock)
int CWE362_Race_Condition__guarded_field_01_bad(counter *c)
{
    /* POTENTIAL FLAW: read with no lock held */
    return c->data;
}
