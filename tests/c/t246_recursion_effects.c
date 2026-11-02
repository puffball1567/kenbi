/* Independent call-graph fixtures, no external implementation. */
extern void external_api(void);
extern void cross_b(int n);
void pure(void) {}
void direct(int n) { if (n) direct(n - 1); } // RECURSION_EXPECT
void mutual_b(int n);
void mutual_a(int n) { if (n) mutual_b(n - 1); }
void mutual_b(int n) { if (n) mutual_a(n - 1); } // RECURSION_EXPECT
void hidden(int n) { mutual_a(n); }
void leaf(void) {}
void left(void) { leaf(); }
void right(void) { leaf(); }
void diamond(void) { left(); right(); }
void repeated(void) { leaf(); leaf(); }
void indirect(void (*callback)(void)) { callback(); }
void external(void) { external_api(); }
void cross_a(int n) { if (n) cross_b(n - 1); }
void block_recursive(int n) {
  // RECURSION_BLOCK inside
  { direct(n); }
}
void block_outside(int n) {
  direct(n);
  // RECURSION_BLOCK outside
  { leaf(); }
}
