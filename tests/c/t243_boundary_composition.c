/* Independently authored synthetic resource model. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern void transfer_start(struct transfer *t, int *b);
extern void transfer_finish(struct transfer *t);
extern void other_init(struct transfer *t);
extern void other_start(struct transfer *t, int *b);
extern void other_finish(struct transfer *t);
void pair_begin(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_start(a,x); transfer_start(b,y);
}
void pair_complete(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_finish(a); transfer_finish(b);
}
void partial_complete(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_finish(a);
}
void swapped(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_start(a,y); transfer_start(b,x);
}
int pair_try(struct transfer *a, int *x, struct transfer *b, int *y, int fail) {
  if (fail) return 1;
  transfer_start(a,x); transfer_start(b,y); return 0;
}
int partial_try(struct transfer *a, int *x, struct transfer *b, int *y, int fail) {
  transfer_start(a,x);
  if (fail) return 1;
  transfer_start(b,y); return 0;
}
void mixed_begin(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_start(a,x); other_start(b,y);
}
void mixed_missing(struct transfer *a, int *x, struct transfer *b, int *y) {
  transfer_start(a,x);
}
void good(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  pair_begin(&a,x,&b,y); pair_complete(&a,x,&b,y);
}
void partial(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  pair_begin(&a,x,&b,y); partial_complete(&a,x,&b,y); transfer_finish(&b);
}
void wrong_buffers(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  swapped(&a,x,&b,y); pair_complete(&a,y,&b,x);
}
void wrong_entry(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  transfer_start(&a,x); pair_complete(&a,x,&b,y);
}
void aliased_resource(void) {
  struct transfer a; int x[4],y[4]; transfer_init(&a);
  pair_begin(&a,x,&a,y);
}
void shared_buffer(void) {
  struct transfer a,b; int x[4]; transfer_init(&a); transfer_init(&b);
  pair_begin(&a,x,&b,x); pair_complete(&a,x,&b,x);
}
void result_good(int fail) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  if (pair_try(&a,x,&b,y,fail)) return;
  pair_complete(&a,x,&b,y);
}
void result_partial(int fail) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  if (partial_try(&a,x,&b,y,fail)) return;
  pair_complete(&a,x,&b,y);
}
void mixed_good(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); other_init(&b);
  mixed_begin(&a,x,&b,y); transfer_finish(&a); other_finish(&b);
}
void mixed_bad(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); other_init(&b);
  mixed_missing(&a,x,&b,y); transfer_finish(&a);
}
void both_wrong_entry(void) {
  struct transfer a,b; int x[4],y[4]; transfer_init(&a); transfer_init(&b);
  pair_complete(&a,x,&b,y);
}
