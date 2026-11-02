// @threadsafe
/* STATE C — the guarded field is read while the lock is provably HELD, so there is no data
   race. GREEN. */
/* CWE: 362 Race Condition — fixed by holding the lock across the access. */
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
typedef struct { pthread_mutex_t lock; int data; } counter;

// @guarded_by(c->data: c->lock)
int CWE362_Race_Condition__guarded_field_01_fixed(counter *c)
{
    pthread_mutex_lock(&c->lock);
    int v = c->data;                     /* FIXED: read while holding the lock */
    pthread_mutex_unlock(&c->lock);
    return v;
}
