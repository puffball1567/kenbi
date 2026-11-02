/* Independently authored capacity-contract fixtures; no device-specific data. */
struct Transfer { int state; };
extern void start(struct Transfer *, char *);
extern void take_int(struct Transfer *, int *);
extern void finish(struct Transfer *);
void helper(struct Transfer *t, char *p) { start(t, p); finish(t); }
void good(void) { struct Transfer t; char b[16]; start(&t, b); finish(&t); }
void small(void) { struct Transfer t; char b[3]; start(&t, b); finish(&t); }
void alias(void) { struct Transfer t; char b[16]; char *p = b; helper(&t, p); }
void nested(void) { struct Transfer t; char b[16]; { char *p = b; helper(&t, p); } helper(&t, b); }
void offset(void) { struct Transfer t; char b[16]; helper(&t, b + 1); }
void indexed(void) { struct Transfer t; char b[16]; helper(&t, &b[1]); }
void offset_alias(void) { struct Transfer t; char b[16]; char *p = b + 1; helper(&t, p); }
void scalar(void) { struct Transfer t; char b; helper(&t, &b); }
void small_helper(void) { struct Transfer t; char b[3]; helper(&t, b); }
void branches(int flag) { struct Transfer t; char b[16]; char small[3]; if (flag) helper(&t, b); else helper(&t, small); }
void loop(int flag) { struct Transfer t; char b[16]; while (flag) helper(&t, b); }
void two_calls(void) { struct Transfer t; char b[16]; char small[3]; helper(&t, b); helper(&t, small); }
void int_parameter(int value) { struct Transfer t; take_int(&t, &value); finish(&t); }
void abi_buffer(void) { struct Transfer t; char b[__SIZEOF_POINTER__]; helper(&t, b); }
