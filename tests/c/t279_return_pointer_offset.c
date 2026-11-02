/* Independently authored byte-offset pointer return contract inputs. */
extern char*view(char*);
extern int*typed_view(int*);
extern void consume(const void*);
int good(void) { char a[8];char*p=view(a);return p[3]; }
int bad(void) { char a[8];char*p=view(a);return p[4]; }
void unused(void) { char a[8];char*p=view(a); }
int back(void) { char a[8];char*p=view(a+4);return p[7]; }
int shifted_input(void) { char a[8];char*p=view(a+4);return *p; }
int typed(void) { int a[4];int*p=typed_view(a);return p[1]; }
void aligned(void) { _Alignas(16) char a[16];char*p=view(a);consume(p); }
int escaped(void) { char*p;{char a[8];p=view(a);}return *p; }
char*visible(char*p) { return p+4; }
int visible_caller(void) { char a[8];char*p=visible(a);return p[3]; }
int relay(void) { char a[16];char*p=view(a);char*q=view(p);return q[7]; }
void unknown(char*p) { char*q=view(p); }
extern void start(int*,char*);
extern void finish(int*);
int conflict(void) { int d;char a[8];start(&d,a);char*p=view(a);int v=*p;finish(&d);return v; }
int completed(void) { int d;char a[8];start(&d,a);char*p=view(a);finish(&d);return *p; }
