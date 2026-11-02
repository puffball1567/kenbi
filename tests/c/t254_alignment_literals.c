/* Independently authored C integer spelling / alignment fixtures. */
struct Transfer { int state; };
extern void start(struct Transfer *, void *);
extern void finish(struct Transfer *);
void helper(struct Transfer *t, void *p) { start(t,p); finish(t); }
void hex(void) { struct Transfer t; _Alignas(0x10) char b[64]; helper(&t,b); }
void upper(void) { struct Transfer t; _Alignas(0X10ULL) char b[64]; helper(&t,b); }
void octal(void) { struct Transfer t; _Alignas(020) char b[64]; helper(&t,b); }
void decimal_suffix(void) { struct Transfer t; _Alignas(16lu) char b[64]; helper(&t,b); }
void octal_suffix(void) { struct Transfer t; _Alignas(020LLU) char b[64]; helper(&t,b); }
void gnu(void) { struct Transfer t; char b[64] __attribute__((aligned(0x10UL))); helper(&t,b); }
void multiple(void) { struct Transfer t; _Alignas(010) _Alignas(0x20u) char b[64]; helper(&t,b); }
void zero(void) { struct Transfer t; _Alignas(00UL) int b[16]; helper(&t,b); }
void hex_zero(void) { struct Transfer t; _Alignas(0x0u) int b[16]; helper(&t,b); }
void shifted(void) { struct Transfer t; _Alignas(020) char b[64]; helper(&t,b+1); }
void large_hex(void) { struct Transfer t; _Alignas(0x80) char b[256]; helper(&t,b); }
#define N 0x10
void macro_value(void) { struct Transfer t; _Alignas(N) char b[64]; helper(&t,b); }
void expression(void) { struct Transfer t; _Alignas(0x8 * 2) char b[64]; helper(&t,b); }
