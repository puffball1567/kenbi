/* Independently authored unsigned-update regression inputs. */
extern void start(int *,const void *);
extern void finish(int *);
extern int poll(int *);
void good(void) { int t;char b[16];for(unsigned i=0;i<4;i++) {start(&t,b);finish(&t);} }
void decrement(void) { int t;char b[16];for(unsigned i=4;i;i--) {start(&t,b);finish(&t);} }
void prefix(void) { int t;char b[16];for(unsigned i=0;i<4;++i) {start(&t,b);finish(&t);} }
void continued(void) { int t;char b[16];for(unsigned i=0;i<4;i++) {start(&t,b);finish(&t);continue;} }
void restart(void) { int t;char b[16];for(unsigned i=0;i<4;i++) {start(&t,b);} }
void conflict(void) { int t;unsigned n=0;start(&t,&n);n++;finish(&t); }
void increment_conflict(void) { int t;for(unsigned n=0;n<4;n++) {start(&t,&n);} }
void completed(void) { int t;unsigned n=0;start(&t,&n);finish(&t);n++; }
int postfix_add(void) { unsigned n=0;n++;return 0; }
int prefix_add(void) { unsigned n=0;++n;return 0; }
int postfix_sub(void) { unsigned n=1;n--;return 0; }
int prefix_sub(void) { unsigned n=1;--n;return 0; }
int wrap_sub(void) { unsigned n=0;n--;return 0; }
int narrow(void) { unsigned char n=255;n++;return 0; }
int wide(void) { unsigned long long n=0;n--;return 0; }
typedef unsigned Count;
int alias_type(void) { Count n=0;n++;return 0; }
int signed_update(void) { int n=0;n++;return n; }
int pointer_update(void) { char b[16];char *p=b;p++;return *p; }
int expression_update(void) { unsigned n=0;return n++; }
int condition_update(void) { unsigned n=4;while(n--) {}return 0; }
int volatile_update(void) { volatile unsigned n=0;n++;return 0; }
unsigned global_n;
int global_update(void) { global_n++;return 0; }
#define INC(n) (++(n))
int macro_update(void) { unsigned n=0;INC(n);return 0; }
int index_unknown(void) { char b[16];unsigned n=0;n++;return b[n]; }
int memory_bad(void) { char b[16];char *p=b+16;for(unsigned n=0;n<4;n++) {return *p;}return 0; }
