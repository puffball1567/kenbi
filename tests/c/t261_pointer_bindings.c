/* Independently authored pointer rebinding regressions. */
extern void consume(const void *);
void good(void) { _Alignas(16) char a[32]; char *p; p=a; consume(p); }
void reassigned(void) { char a[4]; _Alignas(16) char b[32]; char *p=a; p=b; consume(p); }
void small(void) { _Alignas(16) char a[32]; char b[4]; char *p=a; p=b; consume(p); }
void offset(void) { _Alignas(16) char a[32]; char *p=a; p=p+8; consume(p); }
void misaligned(void) { _Alignas(16) char a[32]; char *p=a; p=p+1; consume(p); }
void block_good(void) { char a[4]; _Alignas(16) char b[32]; char *p=a; {p=b;} consume(p); }
void block_bad(void) { _Alignas(16) char a[32]; char b[4]; char *p=a; {p=b;} consume(p); }
void branch(int flag) { _Alignas(16) char a[32]; char b[4]; char *p=a; if(flag) {p=b;} consume(p); }
void shadow(void) { _Alignas(16) char a[32]; char b[4]; char *p=a; {char *p=b; p=b;} consume(p); }
void escaped(void) { _Alignas(16) char a[32]; char *p=a; {_Alignas(16) char b[32]; p=b;} consume(p); }
void readonly(void) { _Alignas(16) char a[32]; _Alignas(16) const char b[32]; const char *p=a; p=b; consume(p); }
void mutable(void) { _Alignas(16) const char a[32]; _Alignas(16) char b[32]; const char *p=a; p=b; consume(p); }
void loop(int flag) { _Alignas(16) char a[32]; char b[4]; char *p=a; while(flag) {p=b;break;} consume(p); }
void continued(int flag) { _Alignas(16) char a[32]; char b[4]; char *p=a; while(flag) {consume(p);p=b;continue;} }
void invalid(void) { _Alignas(16) char a[32]; char *p=a; p=p+40; p=p-40; consume(p); }
void dynamic(int n) { _Alignas(16) char a[32]; char *p=a; p=p+n; consume(p); }
void unknown(const char *q) { _Alignas(16) char a[32]; const char *p=a; p=q; consume(p); }
void null_binding(void) { _Alignas(16) char a[32]; char *p=a; p=0; consume(p); }
char *global_pointer;
void global(void) { _Alignas(16) char a[32]; global_pointer=a; }
void volatile_pointer(void) { _Alignas(16) char a[32]; char *volatile p=a; p=a; }
void local_parameter(char *p) { _Alignas(16) char a[32]; p=a; consume(p); }
void by_value(char *p) { char a[4]; p=a; }
void caller(void) { _Alignas(16) char a[32]; char *p=a; by_value(p); consume(p); }
extern void start(int *,const void *);
extern void finish(int *);
void loan_old(void) { int t; _Alignas(16) char a[32],b[32]; char *p=a; start(&t,p);p=b;consume(a);finish(&t); }
void loan_new(void) { int t; _Alignas(16) char a[32],b[32]; char *p=a; start(&t,p);p=b;consume(p);finish(&t); }
