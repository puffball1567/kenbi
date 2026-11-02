// @threadsafe
/* STATE B — a half-fix: the lock IS taken, but RELEASED before the access, so `c->data` is read
   with the lock NOT held. The held-set is a MUST-property, so it is STILL UNGUARDED_ACCESS. */
/* CWE: 362 Race Condition (unsynchronised access to a guarded field) */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;

// @guarded_by(c->data: c->lock)
int CWE362_Race_Condition__guarded_field_01_bad(counter *c)
{
    pthread_mutex_lock(&c->lock);
    pthread_mutex_unlock(&c->lock);
    /* POTENTIAL FLAW: the lock was released before this read */
    return c->data;
}
