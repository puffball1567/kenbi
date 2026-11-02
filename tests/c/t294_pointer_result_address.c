/* Independently authored addresses of indexed returned pointers. */
char*identity(char*p) { return p; }
char*none(void) { return 0; }
int good(void) { char a[4];char*p=&identity(a)[3];return *p; }
int commuted(void) { char a[4];return *(&3[identity(a)]); }
int nested(void) { char a[4];return *((&identity(a)[4])-1); }
int chosen(int flag) { char a[4],b[4];return *(&(flag?a:b)[3]); }
int assigned(void) { char a[4];char*p=0;p=&identity(a)[3];return *p; }
char*relay(char*p) { return &identity(p)[2]; }
int relayed(void) { char a[4];return relay(a)[1]; }
void write(void) { char a[4];*(&identity(a)[3])=1; }
void one_past(void) { char a[4];char*p=&identity(a)[4]; }
int bad(void) { char a[4];char*p=&identity(a)[5];return 0; }
int negative(void) { char a[4];char*p=&identity(a)[-1];return 0; }
int restored(void) { char a[4];return *((&identity(a)[5])-2); }
int dereference(void) { char a[4];return *(&identity(a)[4]); }
int null_bad(void) { char*p=&none()[0];return 0; }
int different(int flag) { char a[4],b[2];return *(&(flag?identity(a):identity(b))[3]); }
int expired(void) { char*p;{char a[4];p=a;}return *(&identity(p)[1]); }
int unknown(char*p) { return *(&identity(p)[1]); }
int dynamic(int n) { char a[4];return *(&identity(a)[n]); }
extern int index_call(void);
int call_index(void) { char a[4];return *(&identity(a)[index_call()]); }
extern char*view(char*);
int external(void) { char a[4];return *(&view(a)[3]); }
extern int*word(int*);
int misaligned(void) { int a[4];return *(&word(a)[1]); }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*complete(int*d,char*p) { finish(d);return p; }
int transfer(void) { int d;char a[4];start(&d,a);return *(&complete(&d,a)[3]); }
int conflict(void) { int d;char a[4];int n=*(&begin(&d,a)[3]);finish(&d);return n; }
void formation_only(void) { int d;char a[4];char*p=&begin(&d,a)[3];finish(&d); }
