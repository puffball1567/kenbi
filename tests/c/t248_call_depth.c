/* Independent synthetic source-call-depth fixtures. */
extern void external_api(void);
extern void cross_leaf(void);
void leaf(void) {}
void middle(void) { leaf(); }
void deep(void) { middle(); }
void repeated(void) { leaf(); leaf(); }
void branching(int pick) { if(pick) middle(); else leaf(); }
void direct(int n) { if(n) direct(n-1); }
void external(void) { external_api(); }
void cross(void) { cross_leaf(); }
void indirect(void (*callback)(void)) { callback(); }
void block(void) {
  deep();
  // DEPTH_BLOCK
  { leaf(); }
}
