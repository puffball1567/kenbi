/* Independently authored conditional pointer-call regression inputs. */
char*identity(char*p) { return p; }
char*advance(char*p) { return p+1; }
int one(void) { return 1; }
int zero(void) { return 0; }
int good(int flag) { char a[8],b[8];char*p=flag?identity(a):identity(b);return p[7]; }
int bad(int flag) { char a[8],b[4];char*p=flag?identity(a):identity(b);return p[7]; }
int selected(void) { char a[8],b[4];char*p=one()?identity(a):identity(b);return p[7]; }
int selected_bad(void) { char a[8],b[4];char*p=zero()?identity(a):identity(b);return p[7]; }
int nested(int flag) { char a[8];char*p=flag?(one()?identity(a):advance(a)):identity(a);return p[7]; }
int offset_bad(int flag) { char a[8];char*p=flag?advance(a):identity(a);return p[7]; }
int assigned(int flag) { char a[8];char*p=0;p=flag?identity(a):0;return p?*p:0; }
char*relay(char*p,int flag) { return flag?identity(p):0; }
int relayed(int flag) { char a[8];char*p=relay(a,flag);return p?p[7]:0; }
int unguarded(int flag) { char a[8];char*p=flag?identity(a):0;return *p; }
int escaped(int flag) { char*p;{char a[8];p=flag?identity(a):0;}return p?*p:0; }
extern char*view(char*);
int nullable(int flag) { char a[8];char*p=flag?view(a):identity(a);return p?p[7]:0; }
int nullable_bad(int flag) { char a[8];char*p=flag?view(a):identity(a);return *p; }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
void transfer(int flag) { int d;char a[8];char*p=flag?begin(&d,a):0;if(p)finish(&d); }
void leak(int flag) { int d;char a[8];char*p=flag?begin(&d,a):0; }
int conflict(int flag) { int d;char a[8];char*p=flag?begin(&d,a):0;int n=p?*p:0;if(p)finish(&d);return n; }
int condition_start(int*d,char*p) { start(d,p);return 1; }
void condition_transfer(void) { int d;char a[8];char*p=condition_start(&d,a)?identity(a):0;finish(&d); }
int two_nullable(int flag) { char a[8],b[8];char*p=flag?view(a):view(b);return p?p[7]:0; }
int two_nullable_bad(int flag) { char a[8],b[4];char*p=flag?view(a):view(b);return p?p[7]:0; }
int skip_expired(void) { char*p;{char a[8];p=a;}char b[8];char*q=one()?identity(b):identity(p);return q[7]; }
