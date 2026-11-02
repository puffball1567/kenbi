/* Independently authored conditional pointer provenance regression inputs. */
int good(int flag) { char a[8],b[8];char*p=flag?a:b;return p[7]; }
int bad(int flag) { char a[8],b[4];char*p=flag?a:b;return p[7]; }
int null_bad(int flag) { char a[8];char*p=flag?a:0;return *p; }
int null_guard(int flag) { char a[8];char*p=flag?a:0;return p?*p:0; }
int assigned(int flag) { char a[8],b[4];char*p=a;p=flag?a:b;return p[7]; }
int self(int flag) { char a[8];char*p=a;p=flag?p:0;return p?*p:0; }
int offsets(int flag) { char a[8];char*p=flag?a:a+1;return p[7]; }
int unselected(void) { char*p=0;char a[8];char*q=p?p:a;return q[7]; }
int nested(int flag,int other) { char a[8],b[4];char*p=flag?(other?a:b):0;return p?p[7]:0; }
int expired(int flag) { char*p;{char a[8];p=flag?a:0;}return p?*p:0; }
char* choose(char*p,char*q,int flag) { return flag?p:q; }
int returned(int flag) { char a[8],b[4];char*p=choose(a,b,flag);return p[7]; }
char* local_bad(int flag) { char a[8];char*p=a;return flag?p:0; }
int called_bad(int flag) { char*p=local_bad(flag);return p?*p:0; }
extern char*view(char*);
int call_arm(int flag) { char a[8];char*p=flag?view(a):0;return p?*p:0; }
int update_arm(int flag) { char a[8];char*p=a;char*q=flag?p++:p;return *q; }
int indirect(int flag) { char a[8],b[8];return *(flag?a:b); }
extern void start(int*,char*);
extern void finish(int*);
int loan(int flag) { int d;char a[8],b[8];start(&d,a);char*p=flag?a:b;int n=*p;finish(&d);return n; }
int loan_skipped(void) { int d;char a[8],b[8];start(&d,a);char*p=0?a:b;int n=*p;finish(&d);return n; }
extern void consume(const void*);
void alignment(int flag) { _Alignas(16) char a[16];char*p=flag?a:a+1;consume(p); }
void readonly(int flag) { const char a[8]={0};char b[8];const char*p=flag?a:b;consume(p); }
