/* Independently authored result/borrow fixture. */
struct transfer { int opaque; };
extern void transfer_init(struct transfer *t);
extern int try_start(struct transfer *t, int *b);
extern int try_finish(struct transfer *t);
extern void abort_transfer(struct transfer *t);
extern void overwrite(int *value);
int identity(int rc) { return rc; }
int nested_identity(int rc) { return identity(rc); }
void recover(struct transfer *t, int rc) { if (rc == 0) abort_transfer(t); }
void recover_nested(struct transfer *t, int rc) { recover(t, rc); }
void modify_copy(int rc) { rc = 1; }
void modify_copy_pointer(int rc) { overwrite(&rc); }
void lose_result(struct transfer *t, int rc) { rc = 0; if (!rc) abort_transfer(t); }
void lose_by_alias(struct transfer *t, int rc) { int *p = &rc; *p = 0; if (!rc) abort_transfer(t); }
void lose_external(struct transfer *t, int rc) { overwrite(&rc); if (!rc) abort_transfer(t); }
void recover_narrow(struct transfer *t, unsigned char rc) { if (!rc) abort_transfer(t); }
void borrow_parameter(struct transfer *t, int value) { try_start(t, &value); }
void parameter_complete(struct transfer *t, int value) {
  if (try_start(t, &value)) return;
  abort_transfer(t);
}
void parameter_write(struct transfer *t, int value) {
  if (try_start(t, &value)) return;
  value = 7; // RESULT_EXPECT BORROW_ACCESS_CONFLICT
  abort_transfer(t);
}
void good(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); recover(&t,rc);
}
void nested(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); recover_nested(&t,rc);
}
void returned(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b);
  if (identity(rc)) return;
  abort_transfer(&t);
}
void returned_nested(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b);
  if (nested_identity(rc)) return;
  abort_transfer(&t);
}
void independent_copy(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); modify_copy(rc);
  if (rc) return;
  abort_transfer(&t);
}
void independent_address(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); modify_copy_pointer(rc);
  if (rc) return;
  abort_transfer(&t);
}
void overwritten(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); lose_result(&t,rc);
}
void aliased(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); lose_by_alias(&t,rc);
}
void external(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); lose_external(&t,rc);
}
void narrowed(void) {
  struct transfer t; int b[4]; transfer_init(&t);
  int rc = try_start(&t,b); recover_narrow(&t,rc);
}
void escaped_parameter(void) {
  struct transfer t; transfer_init(&t); borrow_parameter(&t,0);
}
void completed_parameter(void) {
  struct transfer t; transfer_init(&t); parameter_complete(&t,0);
}
void changed_parameter(void) {
  struct transfer t; transfer_init(&t); parameter_write(&t,0);
}
void literal_failure(void) {
  struct transfer t; transfer_init(&t); recover(&t,1);
}
void literal_success(void) {
  struct transfer t; transfer_init(&t); recover(&t,0);
}
int completion_result(struct transfer *t) { return try_finish(t); }
