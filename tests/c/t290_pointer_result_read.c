/* Independently authored reads through pointer-returning expressions. */
char*identity(char*p) { return p; }
char*end(char*p) { return p+4; }
char*none(void) { return 0; }
int good(void) { char a[4];return *identity(a); }
int chosen(int flag) { char a[4],b[4];return *(flag?a:b); }
int calls(int flag) { char a[4],b[4];return *(flag?identity(a):identity(b)); }
int nested(int flag) { char a[4];return *(flag?(flag?identity(a):identity(a)):identity(a)); }
int assigned(void) { char a[4];int n;n=*identity(a);return n; }
int initialized(void) { char a[4];int n=*identity(a);return n; }
int negated(void) { char a[4];return !*identity(a); }
int skipped(void) { return 0 && *none(); }
int bad(void) { char a[4];return *end(a); }
int null_bad(void) { return *none(); }
int selected_null(int flag) { char a[4];return *(flag?identity(a):none()); }
int expired(void) { char*p;{char a[4];p=a;}return *identity(p); }
int unknown(char*p) { return *identity(p); }
extern char*view(char*);
int external(void) { char a[4];return *view(a); }
extern int*word(int*);
int misaligned(void) { int a[4];return *word(a); }
extern volatile int*volatile_view(volatile int*);
int volatile_read(void) { volatile int a;return *volatile_view(&a); }
char**pointer_identity(char**p) { return p; }
char*pointer_read(char**p) { return *pointer_identity(p); }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*complete(int*d,char*p) { finish(d);return p; }
int transfer(void) { int d;char a[4];start(&d,a);return *complete(&d,a); }
int conflict(void) { int d;char a[4];int n=*begin(&d,a);finish(&d);return n; }
int after_read(void) { int d;char a[4];start(&d,a);int n=*(1?complete(&d,a):a);return n; }
