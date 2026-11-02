/* Independently authored synthetic API. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern int try_start(struct transfer *t, int *buffer);
extern int try_finish(struct transfer *t);
extern void abort_transfer(struct transfer *t);
int begin(struct transfer *t, int *b) { return try_start(t, b); }
int local_result(struct transfer *t, int *b) { int rc = try_start(t,b); return rc; }
int normalized(struct transfer *t, int *b) {
  if (try_start(t,b)) return 1;
  return 0;
}
int nested(struct transfer *t, int *b) { return begin(t,b); }
int complete(struct transfer *t, int *b) { return try_finish(t); }
int lies_success(struct transfer *t, int *b) { // RESULT_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
  try_start(t,b); return 0;
}
int lies_failure(struct transfer *t, int *b) { // RESULT_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
  try_start(t,b); return 1;
}
int no_start(struct transfer *t, int *b) { return 1; }
int false_start(struct transfer *t, int *b) { return 0; } // RESULT_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
int false_complete(struct transfer *t, int *b) { // RESULT_EXPECT BOUNDARY_POSTCONDITION_MISMATCH
  try_finish(t); return 0;
}
int unknown_result(struct transfer *t, int *b, int value) { return value; } // RESULT_EXPECT UNKNOWN_BOUNDARY_RESULT
unsigned int unsigned_result(struct transfer *t, int *b) { return 1; } // RESULT_EXPECT UNSUPPORTED_BOUNDARY_RESULT
void void_result(struct transfer *t, int *b) {} // RESULT_EXPECT UNSUPPORTED_BOUNDARY_RESULT
int cast_result(struct transfer *t, int *b) {
  int rc = try_start(t,b); return (unsigned char)rc;
}
void good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (begin(&t,b)) return;
  if (complete(&t,b)) abort_transfer(&t);
  b[0] = 1;
}
void local_good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (local_result(&t,b)) return;
  abort_transfer(&t);
}
void normalized_good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (normalized(&t,b)) return;
  abort_transfer(&t);
}
void nested_good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (nested(&t,b)) return;
  abort_transfer(&t);
}
void polling(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (begin(&t,b)) return;
  while (complete(&t,b)) {}
  b[0] = 1;
}
void false_success(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (lies_success(&t,b)) return;
  abort_transfer(&t);
}
void false_failure(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (lies_failure(&t,b)) return;
  abort_transfer(&t);
}
void no_start_good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (no_start(&t,b)) return;
  abort_transfer(&t);
}
void false_start_call(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (false_start(&t,b)) return;
  abort_transfer(&t);
}
void false_complete_call(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (begin(&t,b)) return;
  if (false_complete(&t,b)) abort_transfer(&t);
  b[0] = 1; // RESULT_EXPECT BORROW_ACCESS_CONFLICT
}
void unknown_call(int value) {
  struct transfer t; int b[4]; transfer_init(&t); unknown_result(&t,b,value);
}
void unsigned_call(void) {
  struct transfer t; int b[4]; transfer_init(&t); unsigned_result(&t,b);
}
void void_call(void) {
  struct transfer t; int b[4]; transfer_init(&t); void_result(&t,b);
}
void cast_call(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  cast_result(&t,b);
  /* Caller cannot rely on the narrowed result; no boundary rewrites the actual loan. */
}
void ignored_completion(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  if (begin(&t,b)) return;
  complete(&t,b);
  b[0] = 1; // RESULT_EXPECT BORROW_ACCESS_CONFLICT
}
void wrong_entry(void) {
  struct transfer t; int b[4]; transfer_init(&t); complete(&t,b);
}
