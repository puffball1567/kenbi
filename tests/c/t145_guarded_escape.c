// @threadsafe
// CONCURRENCY v2 — soundness fix for `@guarded_by`: taking the ADDRESS of a guarded field.
// The held-set check only sees accesses spelled as the field (`c->data`). If a pointer to the
// guarded field escapes (`int *p = &c->data;`), writes through that alias (`*p`) are invisible to
// the check — an alias can race after the lock is dropped. So `&<guarded field>` is GUARDED_ESCAPE
// (default-red, UNCONDITIONAL — held or not, since holding the lock now cannot protect later uses
// through the escaped pointer). The sound analogue of UNCONTRACTED_ESCAPE; keep the access inline.
// Padding keeps the file-level @threadsafe marker off the extern decls below.
// padding
typedef struct { int dummy; } pthread_mutex_t;
extern int pthread_mutex_lock(pthread_mutex_t *m);
extern int pthread_mutex_unlock(pthread_mutex_t *m);
extern void sink(int *q);

typedef struct {
  pthread_mutex_t lock;
  int data;            // @guarded_by(lock)
} counter;

// (1) GREEN: inline access under the lock — no address taken, fully verifiable.
int read_inline(counter *c) {
  pthread_mutex_lock(&c->lock);
  int v = c->data;
  pthread_mutex_unlock(&c->lock);
  return v;
}

// (2) RED: the address escapes into an alias; the write `*p` happens after unlock — the race the
// plain held-set check would miss. Caught at the address-taking (line of `&c->data`).
void aliased_race(counter *c) {
  pthread_mutex_lock(&c->lock);
  int *p = &c->data;                   //EXPECT GUARDED_ESCAPE
  pthread_mutex_unlock(&c->lock);
  *p = 5;
}

// (3) RED: the address is passed to an uncontracted callee — kenbi can't verify it stays guarded.
void via_escape(counter *c) {
  sink(&c->data);                      //EXPECT GUARDED_ESCAPE
}

// (4) RED: address taken even with no lock — still an escape (unconditional).
int *leak_addr(counter *c) {
  return &c->data;                     //EXPECT GUARDED_ESCAPE
}

// (5) GREEN: taking the address of the LOCK field is fine — locks are passed by address normally,
// and the lock is not itself guarded data.
void relock(counter *c) {
  pthread_mutex_lock(&c->lock);
  pthread_mutex_unlock(&c->lock);
}
