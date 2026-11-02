/* Independently authored external borrowed pointer return contract inputs. */
extern char*view(char*);
extern int wrong(char*);
extern void consume(const void*);
int good(void) { char a[8];char*p=view(a);return p[7]; }
int bad(void) { char a[8];char*p=view(a);return p[8]; }
int offset(void) { char a[8];char*p=view(a+1);return p[6]; }
int offset_bad(void) { char a[8];char*p=view(a+1);return p[7]; }
int expired(void) { char*p;{char a[8];p=view(a);}return *p; }
void unknown(char*p) { char*q=view(p); }
void null_arg(void) { char*p=view(0); }
void wrong_type(void) { char a[8];wrong(a); }
void unused(void) { char a[8];view(a); }
void alignment(void) { _Alignas(16) char a[16];char*p=view(a+1);consume(p); }
char*visible(char*p) { return p; }
char*shifted(char*p) { return p+1; }
int visible_caller(void) { char a[8];char*p=visible(a);return *p; }
int shifted_caller(void) { char a[8];char*p=shifted(a);return *p; }
extern void start(int*,char*);
extern void finish(int*);
int conflict(void) { int d;char a[8];start(&d,a);char*p=view(a);int v=*p;finish(&d);return v; }
int completed(void) { int d;char a[8];start(&d,a);char*p=view(a);finish(&d);return *p; }
extern const char*const_view(const char*);
void readonly_write(void) { const char a[8]={0};const char*p=const_view(a);consume(p); }
