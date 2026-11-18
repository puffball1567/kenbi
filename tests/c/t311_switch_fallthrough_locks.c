// @threadsafe
// SWITCH FALL-THROUGH, locks. A lock released in one case is not held in the case it falls
// through into, whatever that case's own entry holds: an access there is UNGUARDED_ACCESS, and
// releasing it again after the switch is a double unlock on that path.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

typedef struct { pthread_mutex_t lock; int data; } counter;

// case 1 releases the lock, then falls into case 2's read and the release after the switch
// @guarded_by(c->data: c->lock)
int fall_unlocked(counter *c, int k) {
  int v = 0;
  pthread_mutex_lock(&c->lock);
  switch (k) {
  case 1:
    v = 1;
    pthread_mutex_unlock(&c->lock);
    /* fall through */
  case 2:
    v += c->data;                      //EXPECT UNGUARDED_ACCESS
    break;
  default:
    break;
  }
  pthread_mutex_unlock(&c->lock);      //EXPECT UNLOCK_WITHOUT_LOCK
  return v;
}

// the same with a `return` after the release — clean
// @guarded_by(c->data: c->lock)
int no_fall(counter *c, int k) {
  int v = 0;
  pthread_mutex_lock(&c->lock);
  switch (k) {
  case 1:
    pthread_mutex_unlock(&c->lock);
    return 1;
  case 2:
    v = c->data;
    break;
  default:
    break;
  }
  pthread_mutex_unlock(&c->lock);
  return v;
}
