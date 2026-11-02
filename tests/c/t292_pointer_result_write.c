/* Independently authored writes through pointer-returning expressions. */
char*identity(char*p) { return p; }
char*advance(char*p) { return p+1; }
char*none(void) { return 0; }
void good(void) { char a[4];*identity(a)=1; }
void indexed(void) { char a[4];identity(a)[3]=1; }
void commuted(void) { char a[4];3[identity(a)]=1; }
void chosen(int flag) { char a[4],b[4];*(flag?a:b)=1; }
void calls(int flag) { char a[4],b[4];(flag?identity(a):identity(b))[3]=1; }
void bad(void) { char a[4];identity(a)[4]=1; }
void negative_bad(void) { char a[4];identity(a)[-1]=1; }
void shifted_bad(void) { char a[4];advance(a)[3]=1; }
void different(int flag) { char a[4],b[2];(flag?identity(a):identity(b))[3]=1; }
void null_bad(void) { *none()=1; }
void selected_null(int flag) { char a[4];*(flag?identity(a):none())=1; }
void expired(void) { char*p;{char a[4];p=a;}*identity(p)=1; }
void unknown(char*p) { *identity(p)=1; }
void dynamic(int n) { char a[4];identity(a)[n]=1; }
void read_rhs(int n) { char a[4];*identity(a)=n; }
extern int value(void);
void call_rhs(void) { char a[4];*identity(a)=value(); }
extern char*view(const char*);
void external(void) { char a[4];view(a)[3]=1; }
void readonly(void) { const char a[4]={0};*view(a)=1; }
extern int*word(int*);
void misaligned(void) { int a[4];word(a)[1]=1; }
extern volatile int*volatile_view(volatile int*);
void volatile_write(void) { volatile int a;*volatile_view(&a)=1; }
char**pointer_identity(char**p) { return p; }
void pointer_write(char**p) { *pointer_identity(p)=0; }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*complete(int*d,char*p) { finish(d);return p; }
void transfer(void) { int d;char a[4];start(&d,a);*complete(&d,a)=1; }
void conflict(void) { int d;char a[4];begin(&d,a)[3]=1;finish(&d); }
void after_write(void) { int d;char a[4];start(&d,a);(1?complete(&d,a):a)[3]=1; }
int*integer_identity(int*p) { return p; }
void invalidate(void) { int n=0;char a[4];char*p=a;*integer_identity(&n)=1;if(n)p[4]=1; }
