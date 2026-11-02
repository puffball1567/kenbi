/* Independently authored external-access alignment regression inputs. */
extern void consume(const void *);
extern void unknown_api(void);
void helper(const void *p) { consume(p); }
void good(void) { _Alignas(16) char b[32]; consume(b); }
void offset(void) { _Alignas(16) char b[32]; consume(b+8); }
void misaligned(void) { _Alignas(16) char b[32]; consume(b+1); }
void weak(void) { char b[32]; consume(b); }
void pointer_attribute(void) { char b[32]; _Alignas(16) char *p=b; consume(p); }
void alias(void) { _Alignas(16) char b[32]; char *p=b+8; helper(p); }
void bad_alias(void) { _Alignas(16) char b[32]; char *p=b+1; helper(p); }
void outside(void) { _Alignas(16) char b[32]; consume(b+33); }
void restored(void) { _Alignas(16) char b[32]; char *p=b+40; consume(p-40); }
void dynamic(int n) { _Alignas(16) char b[32]; consume(b+n); }
void unknown(const void *p) { consume(p); }
void readonly(void) { _Alignas(16) const char b[32]; consume(b); }
void small(void) { _Alignas(16) char b[4]; consume(b); }
void gnu(void) { char b[32] __attribute__((aligned(16))); consume(b+8); }
void literal(void) { _Alignas(020UL) char b[32]; consume(b+8); }
#define ALIGNMENT 16
void macro(void) { _Alignas(ALIGNMENT) char b[32]; consume(b); }
void branches(int flag) { _Alignas(16) char b[32]; if(flag) consume(b); else consume(b+1); }
void loop(int flag) { _Alignas(16) char b[32]; while(flag) consume(b+8); }
void unknown_call(void) { _Alignas(16) char b[32]; unknown_api(); consume(b); }
