/* Independently authored synthetic protocol; no external driver code. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern void transfer_start(struct transfer *t, int *buffer);
extern void transfer_finish(struct transfer *t);
extern void external_boundary(struct transfer *t, int *buffer);
void begin(struct transfer *t, int *b) { transfer_start(t, b); }
void complete(struct transfer *t, int *b) { transfer_finish(t); }
void no_completion(struct transfer *t, int *b) {} // BOUNDARY_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
void conditional_completion(struct transfer *t, int *b, int stop) { // BOUNDARY_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
  if (stop) transfer_finish(t);
}
void wrong_buffer(struct transfer *t, int *b, int *other) { // BOUNDARY_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
  transfer_start(t, other);
}
void local_buffer(struct transfer *t, int *b) { // BOUNDARY_EXPECT BORROW_OUTLIVES_BUFFER
  int local[4]; transfer_start(t, local);
}
void bad_write(struct transfer *t, int *b) {
  b[0] = 1; // BOUNDARY_EXPECT BORROW_ACCESS_CONFLICT
  transfer_finish(t);
}
void good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  begin(&t, b); complete(&t, b); b[0] = 1;
}
void wrong_entry(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  complete(&t, b);
}
void retained(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  begin(&t, b); no_completion(&t, b); transfer_finish(&t);
}
void branch_exit(int stop) {
  struct transfer t; int b[4]; transfer_init(&t);
  begin(&t, b); conditional_completion(&t, b, stop);
}
void mismatched_origin(void) {
  struct transfer t; int b[4], other[4]; transfer_init(&t);
  wrong_buffer(&t, b, other); transfer_finish(&t);
}
void mismatched_entry_buffer(void) {
  struct transfer t; int b[4], other[4]; transfer_init(&t);
  begin(&t, b); complete(&t, other);
}
void escaped_local(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  local_buffer(&t, b); transfer_finish(&t);
}
void body_violation(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  begin(&t, b); bad_write(&t, b);
}
void unavailable(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  external_boundary(&t, b); transfer_finish(&t);
}
void aliases(void) {
  struct transfer t; int b[4]; int *alias = b; transfer_init(&t);
  begin(&t, alias); complete(&t, b);
}
void two_resources(void) {
  struct transfer t, u; int b[4], c[4]; transfer_init(&t); transfer_init(&u);
  begin(&t, b); begin(&u, c); complete(&t, b); complete(&u, c);
}
