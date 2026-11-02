/* Original synthetic protocol fixture; no vendor device code or specification.
 * Expected protocol diagnostics are asserted by run_tests_protocols.py.
 * The legacy ownership suite intentionally has no enabled axes here. */
struct device { unsigned opaque; };
void device_init(struct device *d);
void device_start(struct device *d);
void device_finish(struct device *d);
void device_cancel(struct device *d);
void device_ack(struct device *d);
void unrelated(void);
int device_try(struct device *d);

void good(void) {
  struct device d;
  device_init(&d); device_start(&d); device_finish(&d);
}
void before_init(void) {
  struct device d;
  device_start(&d); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void restart(void) {
  struct device d;
  device_init(&d); device_start(&d);
  device_start(&d); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void abandoned(void) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d); device_start(&d);
}
void early(int fail) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d); device_start(&d);
  if (fail) return;
  device_finish(&d);
}
void cancelled(void) {
  struct device d;
  device_init(&d); device_start(&d); device_cancel(&d); device_ack(&d);
}
void cancellation_pending(void) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d); device_start(&d); device_cancel(&d);
}
void wrapped_start(struct device *p) { device_start(p); }
void through_wrapper(void) {
  struct device d;
  device_init(&d); wrapped_start(&d); device_finish(&d);
}
void through_alias(void) {
  struct device d;
  struct device *p = &d;
  device_init(p); device_start(&d); device_finish(p);
}
void branch_join(int flag) {
  struct device d;
  device_init(&d);
  if (flag) device_start(&d);
  device_finish(&d); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void both_branches(int flag) {
  struct device d;
  device_init(&d); device_start(&d);
  if (flag) device_finish(&d);
  else { device_cancel(&d); device_ack(&d); }
}
void loop_good(int more) {
  struct device d;
  device_init(&d);
  while (more) { device_start(&d); device_finish(&d); }
}
void loop_restart(int more) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d);
  while (more) device_start(&d); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void loop_break(void) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d);
  while (1) { device_start(&d); break; }
}
void loop_continue(int more) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d);
  while (more) { device_start(&d); continue; } // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void nested_scope(void) {
  { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
    struct device d;
    device_init(&d); device_start(&d);
  }
}
void two_resources(void) {
  struct device a, b;
  device_init(&a); device_init(&b);
  device_start(&a); device_start(&b);
  device_finish(&a); device_finish(&b);
}
void wrong_resource(void) {
  struct device a, b;
  device_init(&a); device_init(&b); device_start(&a);
  device_finish(&b); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void unknown_external(void) {
  struct device d;
  device_init(&d); unrelated(); // PROTOCOL_EXPECT MISSING_PROTOCOL_CONTRACT
}
void failure_result(void) {
  struct device d;
  device_init(&d); device_try(&d); // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_RESULT
}
void unknown_entry(struct device *d) {
  device_start(d); // PROTOCOL_EXPECT UNKNOWN_PROTOCOL_RESOURCE
}
void pointer_reassignment(void) {
  struct device d;
  struct device *p = &d;
  p = &d; // Tracked local pointer rebinding.
  device_init(p);
}
void dead_branch(void) {
  struct device d;
  device_init(&d);
  if (0) device_start(&d);
}
void recursive(struct device *d) {
  recursive(d); // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_RECURSION
}
void unreachable_after_return(void) {
  struct device d;
  device_init(&d);
  return;
  device_start(&d);
}
void separate_resources(void) {
  struct device a, b;
  device_init(&a); device_init(&b); device_start(&a);
  device_start(&b); device_finish(&b);
  device_start(&a); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void repeated_helper(void) {
  through_wrapper(); through_wrapper();
}
void nested_shadow(void) {
  struct device d;
  device_init(&d); device_start(&d);
  { struct device d; device_init(&d); }
  device_finish(&d);
}
void dead_loop(void) {
  struct device d;
  while (0) device_start(&d);
}
void reset_each_iteration(int more) {
  while (more) {
    struct device d;
    device_init(&d); device_start(&d); device_finish(&d);
  }
}
void loop_return(void) { // PROTOCOL_EXPECT PROTOCOL_EXIT_STATE
  struct device d;
  device_init(&d);
  while (1) { device_start(&d); return; }
}
void cancelled_restart(void) {
  struct device d;
  device_init(&d); device_start(&d); device_cancel(&d);
  device_start(&d); // PROTOCOL_EXPECT PROTOCOL_PRECONDITION
}
void raw_write(void) {
  struct device d;
  device_init(&d);
  d.opaque = 0; // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
struct device global_device;
void global_entry(void) {
  device_init(&global_device); // PROTOCOL_EXPECT UNKNOWN_PROTOCOL_RESOURCE
}
void static_entry(void) {
  static struct device d; // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_MODEL
  device_init(&d);
}
void integer_pointer(void) {
  device_init((struct device *)1234); // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_MODEL
}
void for_loop(void) {
  struct device d;
  for (;;) { device_init(&d); break; } // Tracked for-loop and break.
}
void parameter_bound(struct device *d, int a[(device_start(d), 4)]) {
  (void)a;
}

#define REBIND_PROTOCOL_POINTER(P, Q) ((P) = (Q))
void macro_reassignment(void) {
  struct device a, b;
  struct device *p = &a;
  device_init(p);
  REBIND_PROTOCOL_POINTER(p, &b); // PROTOCOL_EXPECT UNSUPPORTED_PROTOCOL_MODEL
  device_start(p); device_finish(p);
}
void binary_conditions(int flag) {
  struct device d;
  device_init(&d); device_start(&d);
  if ((flag + 1) > 0) device_finish(&d);
  else { device_cancel(&d); device_ack(&d); }
}
