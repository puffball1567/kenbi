/* Independently authored synthetic asynchronous API; no vendor code. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern int try_start(struct transfer *t, int *buffer);
extern int try_finish(struct transfer *t);
extern void abort_transfer(struct transfer *t);
extern void overwrite(int *value);

void good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b);
  if (rc != 0) return;
  if (try_finish(&t) != 0) abort_transfer(&t);
  b[0] = 1;
}
void direct(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (0 == try_start(&t, b)) abort_transfer(&t);
}
void negated(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (!try_start(&t, b)) abort_transfer(&t);
}
void copied(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); int copy = rc;
  if (copy) return;
  abort_transfer(&t);
}
void assigned(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc; rc = try_start(&t, b);
  if (rc) return;
  abort_transfer(&t);
}
void missing_recovery(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  try_finish(&t);
}
void ignored_start(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  try_start(&t, b);
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
void ignored_finish(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  try_finish(&t);
  b[0] = 1; // RESULT_EXPECT BORROW_ACCESS_CONFLICT
}
void polling(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  while (try_finish(&t) != 0) {}
  b[0] = 1;
}
void poll_write(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  while (try_finish(&t)) {
    b[0] = 1; // RESULT_EXPECT BORROW_ACCESS_CONFLICT
  }
}
void poll_break(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  while (try_finish(&t)) { break; }
}
void retry_start(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  while (try_start(&t, b)) {}
  abort_transfer(&t);
}
int helper(struct transfer *t, int *b) { return try_start(t, b); }
int helper_local(struct transfer *t, int *b) {
  int rc = try_start(t, b); return rc;
}
int helper_normalized(struct transfer *t, int *b) {
  if (try_start(t, b)) return 1;
  return 0;
}
void wrapper(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (helper(&t, b)) return;
  abort_transfer(&t);
}
void wrapper_local(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (helper_local(&t, b)) return;
  abort_transfer(&t);
}
void wrapper_normalized(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (helper_normalized(&t, b)) return;
  abort_transfer(&t);
}
void replaced_zero(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); rc = 0;
  if (rc) return;
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
void replaced_nonzero(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); rc = 1;
  if (rc) return;
  abort_transfer(&t);
}
void indirect_overwrite(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); int *alias = &rc; *alias = 0;
  if (rc) return;
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
void external_overwrite(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); overwrite(&rc);
  if (rc) return;
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
void specific_error(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b);
  if (rc == 1) return;
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
void narrowed(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  unsigned char rc = try_start(&t, b); // RESULT_EXPECT UNSUPPORTED_PROTOCOL_MODEL
  if (rc) return;
  abort_transfer(&t);
}
void mixed_read(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (try_start(&t, b)) return;
  if (try_finish(&t) == b[0]) {} // RESULT_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
void short_calls(void) { // RESULT_EXPECT BORROW_NOT_ENDED
  struct transfer t; int b[4]; transfer_init(&t);
  if (!try_start(&t, b) && !try_finish(&t)) {}
}
void copied_then_overwritten(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); int saved = rc; overwrite(&rc);
  if (saved) return;
  abort_transfer(&t);
}
void logical_guard(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b);
  if (rc != 0 || 0) return;
  abort_transfer(&t);
}
void stale_after_finish(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b);
  if (rc) return;
  rc = try_finish(&t);
  if (rc == 0) return;
  abort_transfer(&t);
}
void cast_result(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = (unsigned char)try_start(&t, b); // RESULT_EXPECT UNSUPPORTED_PROTOCOL_MODEL
  if (rc) return;
  abort_transfer(&t);
}
void self_result(void) {
  struct transfer t; transfer_init(&t);
  int rc = try_start(&t, &rc); // RESULT_EXPECT BORROW_ACCESS_CONFLICT
  if (rc) return;
  abort_transfer(&t);
}
void indirect_helper(int *rc) { *rc = 0; }
void helper_overwrite(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t, b); indirect_helper(&rc);
  if (rc) return;
  abort_transfer(&t); // RESULT_EXPECT PROTOCOL_PRECONDITION
}
