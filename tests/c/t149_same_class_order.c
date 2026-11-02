// @threadsafe
// CONCURRENCY v3 STAGE 3 — same-class two-lock canonical order (a deadlock class Rust does NOT
// prevent). When two DISTINCT instances of ONE `@lock_class` are held at once (`a->lock` and
// `b->lock`, both class account_lock), acquiring them without a canonical order risks an AB-BA
// deadlock: thread 1 does transfer(x,y), thread 2 does transfer(y,x), each grabs one and waits on
// the other. The discipline that makes it safe is a canonical ADDRESS order — lock the lower-
// addressed instance first, established by an `if (a < b)` guard. kenbi GATES it: holding two
// same-class instances is RED unless the path proves `firstBase < secondBase`. This needs struct-
// FIELD `@lock_class` (stage 3): the lock keys by INSTANCE (`<base>::lock`) but carries the class,
// so two instances are recognised as a same-class pair rather than one conflated key.
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);

typedef struct account {
  pthread_mutex_t lock;   // @lock_class(account_lock)
  int balance;
} account;

// (1) GREEN: canonical order — the `if (a < b)` guard locks the lower-addressed instance first on
// BOTH branches, so no thread pair can acquire them in opposite orders.
void transfer_ok(account *a, account *b, int amt) {
  if (a < b) {
    pthread_mutex_lock(&a->lock);
    pthread_mutex_lock(&b->lock);
  } else {
    pthread_mutex_lock(&b->lock);
    pthread_mutex_lock(&a->lock);
  }
  a->balance -= amt;
  b->balance += amt;
  pthread_mutex_unlock(&a->lock);
  pthread_mutex_unlock(&b->lock);
}

// (2) RED: two same-class instances locked with NO ordering guard — the classic AB-BA hazard.
void transfer_bad(account *a, account *b, int amt) {
  pthread_mutex_lock(&a->lock);
  pthread_mutex_lock(&b->lock);          //EXPECT SAME_CLASS_NO_ORDER
  a->balance -= amt;
  b->balance += amt;
  pthread_mutex_unlock(&b->lock);
  pthread_mutex_unlock(&a->lock);
}

// (3) RED: a guard is present but the order is BACKWARDS — in the `a < b` branch it locks the
// HIGHER-addressed `b` first, defeating the discipline. kenbi checks the direction, not just the
// presence of a comparison (both branches are wrong here).
void transfer_wrongorder(account *a, account *b, int amt) {
  if (a < b) {
    pthread_mutex_lock(&b->lock);
    pthread_mutex_lock(&a->lock);        //EXPECT SAME_CLASS_NO_ORDER
  } else {
    pthread_mutex_lock(&a->lock);
    pthread_mutex_lock(&b->lock);        //EXPECT SAME_CLASS_NO_ORDER
  }
  pthread_mutex_unlock(&a->lock);
  pthread_mutex_unlock(&b->lock);
}
