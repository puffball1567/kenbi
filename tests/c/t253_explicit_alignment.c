/* Independently authored explicit-alignment regressions. */
struct Transfer { int state; };
extern void start(struct Transfer *, void *);
extern void finish(struct Transfer *);
void helper(struct Transfer *t, void *p) { start(t,p); finish(t); }
void good(void) { struct Transfer t; _Alignas(16) char b[64]; helper(&t,b); }
void gnu(void) { struct Transfer t; char b[64] __attribute__((aligned(16))); helper(&t,b); }
void gnu_alias(void) { struct Transfer t; char b[64] __attribute__((__aligned__(16))); helper(&t,b); }
void multiple(void) { struct Transfer t; _Alignas(8) _Alignas(32) char b[64]; helper(&t,b); }
void multiple_reverse(void) { struct Transfer t; _Alignas(32) _Alignas(8) char b[64]; helper(&t,b); }
void shifted(void) { struct Transfer t; _Alignas(16) char b[64]; helper(&t,b+1); }
void aligned_shift(void) { struct Transfer t; _Alignas(16) char b[64]; helper(&t,b+16); }
void alias(void) { struct Transfer t; _Alignas(16) char b[64]; char *p=b+1; helper(&t,p-1); }
void zero(void) { struct Transfer t; _Alignas(0) int b[16]; helper(&t,b); }
void pointer(void) { struct Transfer t; char b[64]; _Alignas(32) char *p=b; helper(&t,p); }
#define A 32
#define ALIGNED _Alignas(32)
void macro_value(void) { struct Transfer t; _Alignas(A) char b[64]; helper(&t,b); }
void macro_attribute(void) { struct Transfer t; ALIGNED char b[64]; helper(&t,b); }
void type_argument(void) { struct Transfer t; _Alignas(long long) char b[64]; helper(&t,b); }
void expression(void) { struct Transfer t; _Alignas(8+8) char b[64]; helper(&t,b); }
void hex(void) { struct Transfer t; _Alignas(0x10) char b[64]; helper(&t,b); }
void octal(void) { struct Transfer t; _Alignas(020) char b[64]; helper(&t,b); }
void suffix(void) { struct Transfer t; _Alignas(16U) char b[64]; helper(&t,b); }
void unspecified(void) { struct Transfer t; char b[64] __attribute__((aligned)); helper(&t,b); }
void cleanup(char (*b)[64]) { (void)b; }
void other_attribute(void) { struct Transfer t; _Alignas(16) char b[64] __attribute__((cleanup(cleanup))); helper(&t,b); }
#define _Alignas(x) __attribute__((aligned(8)))
void redefined(void) { struct Transfer t; _Alignas(16) char b[64]; helper(&t,b); }
