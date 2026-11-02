/* Independently authored inputs: signed for-loop counters whose update the loop condition keeps
   from overflowing, and near-miss forms that must stay unsupported. */
extern void start(int *t, const void *b);
extern void finish(int *t);

/* ---- accepted: the condition bounds the counter whenever the update runs ---------------------- */

int up(int n) { int x = 0; for (int i = 0; i < n; i++) { x = i; } return x; }
int up_prefix(int n) { int x = 0; for (int i = 0; i < n; ++i) { x = i; } return x; }
int up_commuted(int n) { int x = 0; for (int i = 0; n > i; i++) { x = i; } return x; }
int down(int n) { int x = 0; for (int i = n; i > 0; i--) { x = i; } return x; }
int down_prefix(int n) { int x = 0; for (int i = n; i > 0; --i) { x = i; } return x; }
int down_commuted(int n) { int x = 0; for (int i = n; 0 < i; i--) { x = i; } return x; }
long up_long(long n) { long x = 0; for (long i = 0; i < n; i++) { x = i; } return x; }
int up_constant(void) { int x = 0; for (int i = 0; i < 8; i++) { x = i; } return x; }
int declared_outside(int n) { int i; int x = 0; for (i = 0; i < n; i++) { x = i; } return x; }
int written_before(int n) { int i = 3; int x = 0; i = 0; for (; i < n; i++) { x = i; } return x; }
int written_after(int n) { int i; for (i = 0; i < n; i++) { } i = 7; return i; }
int parenthesized(int n) { int x = 0; for (int i = 0; ((i)) < n; i++) { x = i; } return x; }
int continued(int n) { int x = 0; for (int i = 0; i < n; i++) { if (x) continue; x = i; } return x; }
int parameter_counter(int i, int n) { int x = 0; for (; i < n; i++) { x = i; } return x; }
int two_loops(int n) {
  int x = 0;
  for (int i = 0; i < n; i++) { for (int j = 0; j < i; j++) { x = j; } }
  return x;
}
int reused(int n) { int i; int x = 0; for (i = 0; i < n; i++) { x = i; } for (i = n; i > 0; i--) { x = i; } return x; }

/* ---- accepted, then the protocol inside the loop is checked on every iteration ----------------- */

void balanced(int n) { int t; char b[16]; for (int i = 0; i < n; i++) { start(&t, b); finish(&t); } }
void restarted(int n) { int t; char b[16]; for (int i = 0; i < n; i++) { start(&t, b); } }  /* PROTOCOL_EXPECT PROTOCOL_PRECONDITION */

/* ---- unsupported: the update may overflow, or i may change between the test and the update ---- */

int bound_inclusive(int n) { int x = 0; for (int i = 0; i <= n; i++) { x = i; } return x; }
int wrong_direction(int n) { int x = 0; for (int i = n; i > 0; i++) { x = i; } return x; }
int down_wrong_direction(int n) { int x = 0; for (int i = 0; i < n; i--) { x = i; } return x; }
int not_equal(int n) { int x = 0; for (int i = 0; i != n; i++) { x = i; } return x; }
int no_condition(void) { int x = 0; for (int i = 0;; i++) { if (x) break; x = 1; } return x; }
int wider_bound(long n) { int x = 0; for (int i = 0; i < n; i++) { x = i; } return x; }
int unsigned_bound(unsigned n) { int x = 0; for (int i = 0; i < n; i++) { x = i; } return x; }
int other_variable(int n) { int j = 0; int x = 0; for (int i = 0; i < n; j++) { x = i; } return x + j; }
int written_in_body(int n) { int x = 0; for (int i = 0; i < n; i++) { i = n; x = 1; } return x; }
int added_in_body(int n) { int x = 0; for (int i = 0; i < n; i++) { i += 2; x = 1; } return x; }
int incremented_in_body(int n) { int x = 0; for (int i = 0; i < n; i++) { i++; x = 1; } return x; }
int written_in_condition(int n) { int x = 0; for (int i = 0; (i = i) < n; i++) { x = 1; } return x; }
int address_in_body(int n) { int x = 0; for (int i = 0; i < n; i++) { int *p = &i; x = *p; } return x; }
int address_before(int n) { int i = 0; int *p = &i; int x = 0; for (; i < n; i++) { x = *p; } return x; }
int static_counter(int n) { static int i; int x = 0; for (i = 0; i < n; i++) { x = i; } return x; }
int global_i;
int global_counter(int n) { int x = 0; for (global_i = 0; global_i < n; global_i++) { x = 1; } return x; }
int short_counter(short n) { int x = 0; for (short i = 0; i < n; i++) { x = i; } return x; }
int char_counter(void) { int x = 0; for (signed char i = 0; i < 100; i++) { x = i; } return x; }
int volatile_counter(int n) { int x = 0; for (volatile int i = 0; i < n; i++) { x = 1; } return x; }
#define STEP(v) ((v)++)
int macro_step(int n) { int x = 0; for (int i = 0; i < n; STEP(i)) { x = i; } return x; }
int standalone(int n) { n++; return n; }
