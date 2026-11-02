/* Independently authored constant-index pointer-result reads. */
char*identity(char*p) { return p; }
char*advance(char*p) { return p+1; }
char*end(char*p) { return p+4; }
char*none(void) { return 0; }
int good(void) { char a[4];return identity(a)[3]; }
int commuted(void) { char a[4];return 3[identity(a)]; }
int chosen(int flag) { char a[4],b[4];return (flag?a:b)[3]; }
int calls(int flag) { char a[4],b[4];return (flag?identity(a):identity(b))[3]; }
int nested(int flag) { char a[4];return (flag?(flag?identity(a):identity(a)):identity(a))[3]; }
int assigned(void) { char a[4];int n;n=identity(a)[3];return n; }
int initialized(void) { char a[4];int n=identity(a)[3];return n; }
int negated(void) { char a[4];return !identity(a)[3]; }
int skipped(void) { return 0 && none()[0]; }
int bad(void) { char a[4];return identity(a)[4]; }
int negative_bad(void) { char a[4];return identity(a)[-1]; }
int shifted_bad(void) { char a[4];return advance(a)[3]; }
int back(void) { char a[4];return end(a)[-1]; }
int commuted_bad(void) { char a[4];return 4[identity(a)]; }
int different(int flag) { char a[4],b[2];return (flag?identity(a):identity(b))[3]; }
int fixed_size(void) { char a[4];return identity(a)[sizeof(char)]; }
int null_bad(void) { return none()[0]; }
int selected_null(int flag) { char a[4];return (flag?identity(a):none())[0]; }
int expired(void) { char*p;{char a[4];p=a;}return identity(p)[0]; }
int unknown(char*p) { return identity(p)[0]; }
int dynamic(int n) { char a[4];return identity(a)[n]; }
extern int index_call(void);
int call_index(void) { char a[4];return identity(a)[index_call()]; }
extern char*view(char*);
int external(void) { char a[4];return view(a)[3]; }
extern int*word(int*);
int misaligned(void) { int a[4];return word(a)[1]; }
extern volatile int*volatile_view(volatile int*);
int volatile_read(void) { volatile int a[4];return volatile_view(a)[1]; }
char**pointer_identity(char**p) { return p; }
char*pointer_read(char**p) { return pointer_identity(p)[0]; }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*complete(int*d,char*p) { finish(d);return p; }
int transfer(void) { int d;char a[4];start(&d,a);return complete(&d,a)[3]; }
int conflict(void) { int d;char a[4];int n=begin(&d,a)[3];finish(&d);return n; }
int after_read(void) { int d;char a[4];start(&d,a);int n=(1?complete(&d,a):a)[3];return n; }
