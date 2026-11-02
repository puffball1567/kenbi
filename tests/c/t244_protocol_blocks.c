/* Independently authored fixture. BLOCK_VERIFY markers are activated individually by the CLI test. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern void transfer_start(struct transfer *t, int *b);
extern void transfer_finish(struct transfer *t);
extern void wait_api(void);
extern void unknown_api(void);
extern void cross_begin(struct transfer *t, int *b);
void begin(struct transfer *t, int *b) { transfer_start(t,b); }
void complete(struct transfer *t) { transfer_finish(t); }
void good(void) {
  struct transfer t; int b[4]; transfer_init(&t); transfer_start(&t,b);
  // BLOCK_VERIFY good
  { transfer_finish(&t); }
  b[0] = 1;
}
void start_in(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  // BLOCK_VERIFY start_in
  { transfer_start(&t,b); }
  transfer_finish(&t); b[0] = 1;
}
void bad_before(void) {
  struct transfer t; int b[4]; transfer_start(&t,b);
  // BLOCK_VERIFY bad_before
  { transfer_finish(&t); }
}
void bad_after(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  // BLOCK_VERIFY bad_after
  { transfer_start(&t,b); }
  b[0] = 1; // BLOCK_EXPECT BORROW_ACCESS_CONFLICT
  transfer_finish(&t);
}
void short_buffer(void) {
  struct transfer t; transfer_init(&t);
  // BLOCK_VERIFY short_buffer
  { int b[4]; transfer_start(&t,b); }
  transfer_finish(&t);
}
void early_return(void) {
  struct transfer t; int b[4]; transfer_init(&t); transfer_start(&t,b);
  // BLOCK_VERIFY early_return
  { return; }
}
void loop_good(int again) {
  struct transfer t; int b[4]; transfer_init(&t);
  while (again) {
    transfer_start(&t,b);
    // BLOCK_VERIFY loop_good
    { transfer_finish(&t); }
  }
}
void loop_bad(int again) {
  struct transfer t; int b[4]; transfer_init(&t);
  while (again) {
    // BLOCK_VERIFY loop_bad
    { transfer_start(&t,b); }
  }
}
void helpers(void) {
  struct transfer t; int b[4]; transfer_init(&t); begin(&t,b);
  // BLOCK_VERIFY helpers
  { complete(&t); }
}
void external_before(void) {
  wait_api();
  struct transfer t; int b[4]; transfer_init(&t); transfer_start(&t,b);
  // BLOCK_VERIFY external_before
  { transfer_finish(&t); }
}
void external_inside(void) {
  struct transfer t; int b[4]; transfer_init(&t); transfer_start(&t,b);
  // BLOCK_VERIFY external_inside
  { wait_api(); transfer_finish(&t); }
}
void unknown_before(void) {
  unknown_api();
  struct transfer t; int b[4]; transfer_init(&t); transfer_start(&t,b);
  // BLOCK_VERIFY unknown_before
  { transfer_finish(&t); }
}
void nested(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  // BLOCK_VERIFY nested_outer
  {
    transfer_start(&t,b);
    // BLOCK_VERIFY nested_inner
    { transfer_finish(&t); }
  }
}
void cross(void) {
  struct transfer t; int b[4]; transfer_init(&t); cross_begin(&t,b);
  // BLOCK_VERIFY cross
  { transfer_finish(&t); }
}
void unknown_entry(struct transfer *t) {
  // BLOCK_VERIFY unknown_entry
  { transfer_finish(t); }
}
