/* Independently authored pointer-formation regressions. */
void good(void) { char b[16];char *p=b+8; }
void one_past(void) { char b[16];char *p=b+16; }
void scalar_end(void) { int n;int *p=&n+1; }
void outside(void) { char b[16];char *p=b+17; }
void before(void) { char b[16];char *p=b-1; }
void typed(void) { int b[4];int *p=b+4; }
void typed_bad(void) { int b[4];int *p=b+5; }
void indexed(void) { char b[16];char *p=&b[16]; }
void indexed_bad(void) { char b[16];char *p=b;char *q=&p[17]; }
void restored(void) { char b[16];char *p=(b+17)-17; }
void unknown(int n) { char b[16];char *p=b+n; }
void origin(char *p) { char *q=p+1; }
void null_pointer(void) { char *p=0;char *q=p+0; }
void expired(void) { char *p;{char b[16];p=b;}char *q=p+0; }
void reassigned(void) { char b[16];char *p=b;p=p+17; }
void ignored(char *p) { }
void unused_callee(void) { char b[16];ignored(b+17); }
void helper(char *p) { char *q=p+8; }
void call_good(void) { char b[16];helper(b+8); }
void call_bad(void) { char b[16];helper(b+9); }
void branch(int flag) { char b[16];char *p=b;if(flag) {p=b+17;} }
void dead_branch(void) { char b[16];char *p=b+1;if(0) {p=b+17;} }
int end_read(void) { char b[16];char *p=b+16;return *p; }
extern void start(int *,const void *);
extern void finish(int *);
void loan_address(void) { int t;char b[16];start(&t,b);char *p=b+8;finish(&t); }
void loan_read(void) { int t;char b[16];start(&t,b);char *p=b+8;int x=*p;finish(&t); }
