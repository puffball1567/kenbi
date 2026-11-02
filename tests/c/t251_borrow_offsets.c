/* Independently authored byte-offset and capacity regressions. */
struct Transfer { int state; };
extern void start(struct Transfer *, void *);
extern void finish(struct Transfer *);
void helper(struct Transfer *t, void *p) { start(t, p); finish(t); }
void zero(void) { struct Transfer t; char b[16]; helper(&t, b + 0); }
void plus(void) { struct Transfer t; char b[16]; helper(&t, b + 1); }
void indexed(void) { struct Transfer t; char b[16]; helper(&t, &b[1]); }
void alias(void) { struct Transfer t; char b[16]; char *p = b + 1; helper(&t, p); }
void restored(void) { struct Transfer t; char b[16]; char *p = b + 8; helper(&t, p - 8); }
void end_restored(void) { struct Transfer t; char b[16]; char *p = b + 16; helper(&t, p - 16); }
void end(void) { struct Transfer t; char b[16]; helper(&t, b + 16); }
void beyond(void) { struct Transfer t; char b[16]; helper(&t, b + 17); }
void before(void) { struct Transfer t; char b[16]; helper(&t, b - 1); }
void invalid_restore(void) { struct Transfer t; char b[16]; helper(&t, (b + 17) - 17); }
void invalid_alias(void) { struct Transfer t; char b[16]; char *p = b + 17; helper(&t, p - 17); }
void unknown(int n) { struct Transfer t; char b[16]; helper(&t, b + n); }
void unknown_restore(int n) { struct Transfer t; char b[16]; char *p = b + n; helper(&t, p - n); }
void typed(void) { struct Transfer t; short b[8]; helper(&t, b + 1); }
void typed_index(void) { struct Transfer t; short b[8]; helper(&t, &b[1]); }
void nested(void) { struct Transfer t; char b[16]; helper(&t, (b + 4) + 4); }
void huge(void) { struct Transfer t; char b[16]; helper(&t, b + 0xffffffffffffffffULL); }
void product_overflow(void) { struct Transfer t; short b[8]; helper(&t, b + 0x7fffffffffffffffLL); }
void negative_literal(void) { struct Transfer t; char b[16]; helper(&t, b + -1); }
void subtract_negative(void) { struct Transfer t; char b[16]; helper(&t, b - -1); }
void leaf(struct Transfer *t, char *p) { helper(t, p - 4); }
void callee_restore(void) { struct Transfer t; char b[16]; leaf(&t, b + 4); }
void changed_index(void) { struct Transfer t; char b[16]; int n = 0; n = 1; helper(&t, b + n); }
void large_representable(void) { struct Transfer t; char b[16]; helper(&t, b + 0x7fffffffffffffffLL); }
void indexed_end(void) { struct Transfer t; char b[16]; helper(&t, &b[16]); }
void invalid_unknown(int n) { struct Transfer t; char b[16]; helper(&t, (b + 17) + n); }
