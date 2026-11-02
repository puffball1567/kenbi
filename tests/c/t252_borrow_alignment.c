/* Independently authored target-layout and borrow-alignment fixtures. */
struct Transfer { int state; };
extern void start(struct Transfer *, void *);
extern void finish(struct Transfer *);
void helper(struct Transfer *t, void *p) { start(t, p); finish(t); }
void good(void) { struct Transfer t; int b[8]; helper(&t, b); }
void weak(void) { struct Transfer t; char b[32]; helper(&t, b); }
void shifted(void) { struct Transfer t; int b[8]; void *v = b; char *p = v; helper(&t, p + 1); }
void aligned_shift(void) { struct Transfer t; int b[8]; void *v = b; char *p = v; helper(&t, p + 4); }
void restored(void) { struct Transfer t; int b[8]; void *v = b; char *p = v; char *q = p + 1; helper(&t, q - 1); }
void typed(void) { struct Transfer t; int b[8]; helper(&t, b + 1); }
void dynamic(int n) { struct Transfer t; int b[8]; void *v = b; char *p = v; helper(&t, p + n); }
void beyond(void) { struct Transfer t; int b[8]; helper(&t, b + 9); }
void abi(void) { struct Transfer t; long long b[4]; helper(&t, b); }
void parameter(int b) { struct Transfer t; helper(&t, &b); }
void explicit_alignment(void) { struct Transfer t; _Alignas(16) char b[32]; helper(&t, b); }
void pair(void) { struct Transfer t; int b[8]; char c[32]; helper(&t, b); helper(&t, c); }
void conditional(int flag) { struct Transfer t; int b[8]; void *v = b; char *p = v; if (flag) helper(&t, p); else helper(&t, p + 1); }
void repeated(int flag) { struct Transfer t; int b[8]; while (flag) helper(&t, b); }
