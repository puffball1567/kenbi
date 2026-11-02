/* Independently authored inputs: worst-case stack along the call graph from per-function frames. */
extern void bounded_api(void);     /* declares maxStackBytes */
extern void unbounded_api(void);   /* declares none */

static int leaf(int x) { return x + 1; }
int mid(int x) { return leaf(x) + leaf(x + 1); }
int top(void) { return mid(1); }
int two_paths(int c) { if (c) return mid(1); return leaf(2); }
int calls_bounded(void) { bounded_api(); return leaf(0); }
int calls_unbounded(void) { unbounded_api(); return 0; }
int recursive(int n) { return n ? recursive(n - 1) : 0; }
int through_pointer(int (*f)(void)) { return f(); }
int variable_frame(int n) { return leaf(n); }
int unreported(void) { return 0; }
int calls_unreported(void) { return unreported(); }
static int
name_on_next_line(void) { return 1; }
int uses_next_line(void) { return name_on_next_line(); }
void isr_low(void) { leaf(1); }
void isr_mid(void) { leaf(2); }
void isr_high(void) { mid(1); }
void isr_unreported(void) { }
