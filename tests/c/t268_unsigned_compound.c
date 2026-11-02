/* Independently authored unsigned compound-assignment regression inputs. */
extern void start(int *,const void *);
extern void finish(int *);
extern int poll(int *);
void good(void) { int t;char b[16];for(unsigned i=0;i<4;i+=1) {start(&t,b);finish(&t);} }
void decrement(void) { int t;char b[16];for(unsigned i=4;i;i-=1) {start(&t,b);finish(&t);} }
void prefix(void) { int t;char b[16];for(unsigned i=0;i<4;i+=1) {start(&t,b);finish(&t);} }
void continued(void) { int t;char b[16];for(unsigned i=0;i<4;i+=1) {start(&t,b);finish(&t);continue;} }
void restart(void) { int t;char b[16];for(unsigned i=0;i<4;i+=1) {start(&t,b);} }
void conflict(void) { int t;unsigned n=0;start(&t,&n);n+=1;finish(&t); }
void increment_conflict(void) { int t;for(unsigned n=0;n<4;n+=1) {start(&t,&n);} }
void completed(void) { int t;unsigned n=0;start(&t,&n);finish(&t);n+=1; }
int postfix_add(void) { unsigned n=0;n+=1;return 0; }
int prefix_add(void) { unsigned n=0;n+=1;return 0; }
int postfix_sub(void) { unsigned n=1;n-=1;return 0; }
int prefix_sub(void) { unsigned n=1;n-=1;return 0; }
int wrap_sub(void) { unsigned n=0;n-=1;return 0; }
int narrow(void) { unsigned char n=255;n+=1;return 0; }
int wide(void) { unsigned long long n=0;n-=1;return 0; }
typedef unsigned Count;
int alias_type(void) { Count n=0;n+=1;return 0; }
int signed_update(void) { int n=0;n+=1;return n; }
int pointer_update(void) { char b[16];char *p=b;p++;return *p; }
int expression_update(void) { unsigned n=0;return (n+=1); }
int condition_update(void) { unsigned n=4;while(n-=1) {}return 0; }
int volatile_update(void) { volatile unsigned n=0;n+=1;return 0; }
unsigned global_n;
int global_update(void) { global_n+=1;return 0; }
#define INC(n) (++(n))
int macro_update(void) { unsigned n=0;INC(n);return 0; }
int index_unknown(void) { char b[16];unsigned n=0;n+=1;return b[n]; }
int memory_bad(void) { char b[16];char *p=b+16;for(unsigned n=0;n<4;n+=1) {return *p;}return 0; }

int rhs_good(void) { unsigned n=0;unsigned b[2];n+=b[1];return 0; }
int rhs_bad(void) { unsigned n=0;unsigned b[2];unsigned*p=b;n+=p[2];return 0; }
int wider_signed(long long x) { unsigned n=0;n+=x;return 0; }
extern unsigned get_value(void);
int call_rhs(void) { unsigned n=0;n+=get_value();return 0; }
void rhs_conflict(void) { int t;unsigned b[2];unsigned n=0;start(&t,b);n+=b[0];finish(&t); }
int self_update(void) { unsigned n=1;n+=n;return 0; }
int parameter(unsigned n) { n-=1;return 0; }
int multiply(void) { unsigned n=1;n*=2;return 0; }
