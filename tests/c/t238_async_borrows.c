/* Original synthetic API and buffers; no vendor driver/specification content.
 * BORROW_EXPECT assertions run through the --safety CLI, not the legacy axes. */
struct transfer { unsigned opaque; };
void transfer_init(struct transfer *t);
void transfer_start(struct transfer *t, unsigned char *buffer);
void transfer_finish(struct transfer *t);
void transfer_cancel(struct transfer *t);
void transfer_ack(struct transfer *t);
void buffer_write(unsigned char *buffer);
void buffer_read(unsigned char *buffer);
void buffer_release(unsigned char *buffer);
void buffer_relocate(unsigned char *buffer);
void unrelated(void);
void free(void *p);

void good(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b); transfer_finish(&t);
  b[0] = 1;
}
void cpu_write(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  b[0] = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
  transfer_finish(&t);
}
int cpu_read(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  int value = b[0]; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  return value;
}
void release_early(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  buffer_release(b); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void relocate_early(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  buffer_relocate(b); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void alias_write(void) {
  struct transfer t;
  unsigned char b[16];
  unsigned char *p = b;
  transfer_init(&t); transfer_start(&t, p);
  b[3] = 7; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void interior_write(void) {
  struct transfer t;
  unsigned char b[16];
  unsigned char *p = &b[4];
  transfer_init(&t); transfer_start(&t, p);
  *(b + 2) = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void missing_completion(int fail) { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER BORROW_NOT_ENDED
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  if (fail) return;
  transfer_finish(&t);
}
void cancellation_pending(void) { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER BORROW_NOT_ENDED
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); transfer_cancel(&t);
}
void cancellation_complete(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); transfer_cancel(&t); transfer_ack(&t);
  b[0] = 5;
}
void begin_helper(struct transfer *t, unsigned char *b) { transfer_start(t, b); }
void finish_helper(struct transfer *t) { transfer_finish(t); }
void through_helpers(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); begin_helper(&t, b); finish_helper(&t);
  b[0] = 2;
}
void helper_does_not_end_borrow(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); begin_helper(&t, b);
  b[0] = 2; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void short_buffer(void) {
  struct transfer t;
  transfer_init(&t);
  { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER
    unsigned char b[16];
    transfer_start(&t, b);
  }
  transfer_finish(&t);
}
void helper_local(struct transfer *t) { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER
  unsigned char b[16];
  transfer_start(t, b);
}
void escaped_helper_buffer(void) {
  struct transfer t;
  transfer_init(&t); helper_local(&t); transfer_finish(&t);
}
void two_readers(void) {
  struct transfer a, b;
  unsigned char buffer[16];
  transfer_init(&a); transfer_init(&b);
  transfer_start(&a, buffer);
  transfer_start(&b, buffer); // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&a); transfer_finish(&b);
}
void one_reader_left(void) {
  struct transfer a, b;
  unsigned char buffer[16];
  transfer_init(&a); transfer_init(&b);
  transfer_start(&a, buffer); transfer_start(&b, buffer);
  transfer_finish(&a);
  buffer[0] = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void separate_buffers(void) {
  struct transfer a, b;
  unsigned char x[16], y[16];
  transfer_init(&a); transfer_init(&b);
  transfer_start(&a, x); transfer_start(&b, y);
  transfer_finish(&a); x[0] = 1; transfer_finish(&b); y[0] = 2;
}
void loop_good(int more) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t);
  while (more) { transfer_start(&t, b); transfer_finish(&t); }
  b[0] = 3;
}
void loop_missing(int more) { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER BORROW_NOT_ENDED
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t);
  while (more) transfer_start(&t, b);
}
void branch_missing(int flag) { // BORROW_EXPECT BORROW_OUTLIVES_BUFFER BORROW_NOT_ENDED
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  if (flag) transfer_finish(&t);
}
void both_paths(int flag) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  if (flag) transfer_finish(&t);
  else { transfer_cancel(&t); transfer_ack(&t); }
  b[0] = 1;
}
void external_write(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  buffer_write(b); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void external_read(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  buffer_read(b); // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
}
void external_unknown(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  unrelated(); // BORROW_EXPECT MISSING_MEMORY_CONTRACT
  transfer_finish(&t);
}
void expired_buffer(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); buffer_release(b);
  transfer_start(&t, b); // BORROW_EXPECT EXPIRED_BORROW_ORIGIN
}
void relocated_buffer(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); buffer_relocate(b);
  transfer_start(&t, b); // BORROW_EXPECT EXPIRED_BORROW_ORIGIN
}
void known_free_helper(unsigned char *p) {
  free(p); // BORROW_EXPECT BORROW_ACCESS_CONFLICT //EXPECT UNCONTRACTED_RELEASE
}
void known_free(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); known_free_helper(b);
}
void unknown_buffer(unsigned char *b) {
  struct transfer t;
  transfer_init(&t);
  transfer_start(&t, b); // BORROW_EXPECT UNKNOWN_BORROW_ORIGIN
}
void scalar_write(void) {
  struct transfer t;
  unsigned char b = 0;
  transfer_init(&t); transfer_start(&t, &b);
  b = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
int scalar_read(void) {
  struct transfer t;
  unsigned char b = 0;
  transfer_init(&t); transfer_start(&t, &b);
  int value = b; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  return value;
}
int condition_read(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  if (b[0]) { transfer_finish(&t); return 1; } // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  return 0;
}
void while_read(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  while (b[0]) { break; } // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
}

void cancel_write(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); transfer_cancel(&t);
  b[0] = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
  transfer_ack(&t);
}
void complete_without_start(void) {
  struct transfer t;
  transfer_init(&t);
  transfer_finish(&t); // BORROW_EXPECT BORROW_NOT_ACTIVE (permissive state model only)
}
void local_resource(unsigned char *b) { // BORROW_EXPECT BORROW_NOT_ENDED
  struct transfer t;
  transfer_init(&t); transfer_start(&t, b);
}
void resource_escapes(void) {
  unsigned char b[16];
  local_resource(b);
}
void release_after_completion(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); transfer_finish(&t);
  buffer_release(b);
}
void short_circuit(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  if (0 && b[0]) { }
  if (1 || b[0]) { }
  transfer_finish(&t);
}
void reads_offset(void) {
  struct transfer t;
  unsigned char index = 0, b[16] = {0};
  transfer_init(&t); transfer_start(&t, &index);
  int value = *(b + index); // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  if (value) { }
}
void address_reads_offset(void) {
  struct transfer t;
  unsigned char index = 0, b[16];
  transfer_init(&t); transfer_start(&t, &index);
  unsigned char *p = &b[index]; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  *p = 1;
}
void writes_offset(void) {
  struct transfer t;
  unsigned char index = 0, b[16];
  transfer_init(&t); transfer_start(&t, &index);
  *(b + index) = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
}
void disjoint_offsets(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, &b[8]);
  b[0] = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (conservative whole-origin model)
}
void forged_pointer(void) {
  struct transfer t;
  transfer_init(&t);
  transfer_start(&t, (unsigned char *)1234); // BORROW_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
void unsupported_compound(void) {
  struct transfer t;
  unsigned char b[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  b[0] += 1; // BORROW_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
void helper_write(unsigned char *p) {
  *p = 1; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void through_mutator(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b); helper_write(b);
}

enum sample { sample_zero, sample_one };
int enum_read(void) {
  struct transfer t;
  enum sample b = sample_zero;
  void *address = &b;
  transfer_init(&t); transfer_start(&t, address);
  int value = b; // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
  return value;
}
void enum_write(void) {
  struct transfer t;
  enum sample b = sample_zero;
  void *address = &b;
  transfer_init(&t); transfer_start(&t, address);
  b = sample_one; // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void self_borrow(void) {
  struct transfer t;
  void *address = &t;
  transfer_init(&t);
  transfer_start(address, address); // BORROW_EXPECT UNSUPPORTED_RESOURCE_BORROW
}

void *memcpy(void *dst, const void *src, __SIZE_TYPE__ length);
void *memmove(void *dst, const void *src, __SIZE_TYPE__ length);
void *memset(void *dst, int value, __SIZE_TYPE__ length);
void builtin_write(void) {
  struct transfer t;
  unsigned char b[16], source[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  memcpy(b, source, 16); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void builtin_read(void) {
  struct transfer t;
  unsigned char b[16] = {0}, destination[16];
  transfer_init(&t); transfer_start(&t, b);
  memcpy(destination, b, 16); // BORROW_EXPECT BORROW_ACCESS_CONFLICT (receive model only)
  transfer_finish(&t);
}
void builtin_move(void) {
  struct transfer t;
  unsigned char b[16], source[16] = {0};
  transfer_init(&t); transfer_start(&t, b);
  memmove(b, source, 16); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}
void builtin_set(void) {
  struct transfer t;
  unsigned char b[16];
  transfer_init(&t); transfer_start(&t, b);
  memset(b, 0, 16); // BORROW_EXPECT BORROW_ACCESS_CONFLICT
}

void volatile_store(void) {
  volatile unsigned char value = 0;
  value = 1; // BORROW_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
