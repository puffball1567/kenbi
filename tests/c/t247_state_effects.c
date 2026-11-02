/* Independent synthetic lifecycle and API, not a hardware specification. */
struct phase { int opaque; };
extern void phase_begin(struct phase *p);
extern void phase_seal(struct phase *p);
extern void phase_stop(struct phase *p);
extern void allocate_api(void);
extern void blocking_api(void);
extern void waiting_api(void);
extern void unknown_api(void);
void allocate_helper(void) { allocate_api(); }
void stop_then_allocate(struct phase *p) { phase_stop(p); allocate_api(); }
void seal_then_allocate(struct phase *p) { phase_seal(p); allocate_api(); }
void recursive(int n) { if(n) recursive(n-1); }
void good(void) {
  struct phase p; phase_begin(&p); allocate_api(); phase_seal(&p); phase_stop(&p);
}
void bad(void) {
  struct phase p; phase_begin(&p); phase_seal(&p);
  allocate_api(); // STATE_EXPECT STATE_FORBIDDEN_EFFECT
  phase_stop(&p);
}
void indirect_bad(void) {
  struct phase p; phase_begin(&p); phase_seal(&p); allocate_helper(); phase_stop(&p);
}
void body_order_good(void) {
  struct phase p; phase_begin(&p); phase_seal(&p); stop_then_allocate(&p);
}
void body_order_bad(void) {
  struct phase p; phase_begin(&p); seal_then_allocate(&p); phase_stop(&p);
}
void branching(int sealed) {
  struct phase p; phase_begin(&p);
  if(sealed) phase_seal(&p);
  allocate_api(); // STATE_EXPECT STATE_FORBIDDEN_EFFECT
}
void waiting(void) {
  struct phase p; phase_begin(&p); phase_seal(&p); waiting_api(); phase_stop(&p);
}
void blocking(void) {
  struct phase p; phase_begin(&p); phase_seal(&p); blocking_api(); phase_stop(&p);
}
void loop_bad(int again) {
  struct phase p; phase_begin(&p);
  while(again) { allocate_api(); phase_seal(&p); }
}
void loop_good(int again) {
  struct phase p;
  while(again) { phase_begin(&p); allocate_api(); phase_seal(&p); phase_stop(&p); }
}
void two_guards(void) {
  struct phase p,q; phase_begin(&p); phase_begin(&q); phase_seal(&p); phase_seal(&q);
  phase_stop(&p); allocate_api(); phase_stop(&q);
}
void ended(void) {
  { struct phase p; phase_begin(&p); phase_seal(&p); phase_stop(&p); }
  allocate_api();
}
void abandoned(void) {
  struct phase p; phase_begin(&p); phase_seal(&p);
}
void missing(void) {
  struct phase p; phase_begin(&p); phase_seal(&p); unknown_api(); phase_stop(&p);
}
void recursion_bad(int n) {
  struct phase p; phase_begin(&p); phase_seal(&p); recursive(n); phase_stop(&p);
}
