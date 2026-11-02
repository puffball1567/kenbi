/* Independently authored visible pointer-result propagation inputs. */
char* identity(char*p) { return p; }
char* advance(char*p) { return p+1; }
char* relay(char*p) { return advance(p); }
int good(void) { char a[8];char*p=identity(a);return p[7]; }
int bad(void) { char a[8];char*p=identity(a);return p[8]; }
int offset(void) { char a[8];char*p=advance(a);return p[6]; }
int offset_bad(void) { char a[8];char*p=advance(a);return p[7]; }
int relayed(void) { char a[8];char*p=relay(a);return p[6]; }
int relayed_bad(void) { char a[8];char*p=relay(a);return p[7]; }
int assigned(void) { char a[8];char*p=0;p=advance(a);return p[6]; }
int preserve_alias(void) { char a[8];char*p=a;char*q=p;p=advance(p);return q[7]; }
int escaped(void) { char*p;{char a[8];p=identity(a);}return *p; }
char* null_helper(void) { return 0; }
char* null_relay(void) { return null_helper(); }
int null_read(void) { char*p=null_helper();return *p; }
char* choose(char*p,char*q,int flag) { if(flag)return p;return q; }
int branch(int flag) { char a[8],b[4];char*p=choose(a,b,flag);return p[7]; }
const int* readonly_helper(const int*p) { return p; }
int readonly(void) { const int a=1;const int*p=readonly_helper(&a);return *p; }
int unsupported_nested(void) { char a[8];return *identity(a); }
extern char*external(char*);
void external_result(void) { char a[8];char*p=external(a); }
extern void consume(const void*);
void capacity(void) { _Alignas(16) char a[16];char*p=advance(a);consume(p); }
extern void start(int*,char*);
extern void finish(int*);
int loan_conflict(void) { int d;char a[8];start(&d,a);char*p=identity(a);int v=*p;finish(&d);return v; }
int loan_finished(void) { int d;char a[8];start(&d,a);char*p=identity(a);finish(&d);return *p; }
void readonly_write(void) { const int a=1;const int*p=readonly_helper(&a);consume(p); }
void nothing(void) {}
int successive(void) { char a[8],b[4];char*p=identity(a);nothing();p=identity(b);return p[7]; }
char* local_bad(void) { char a[8];char*p=a;return p; } //EXPECT DANGLING_RETURN
int local_result(void) { char*p=local_bad();return *p; }
int formation_bad(void) { char a[8];char*p=advance(a+8);return *p; }
void do_rebind(int flag) { char a[8];char*p=a;do{p=advance(p);}while(flag); }
