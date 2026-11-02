/* Independently authored for-loop state, lifetime and access regressions. */
extern void start(int *,const void *);
extern void finish(int *);
extern int poll(int *);
void good(void) { int t;char b[16];for(start(&t,b);poll(&t);) {} }
void continued(void) { int t;char b[16];for(start(&t,b);poll(&t);) {continue;} }
void increment(void) { int t;char b[16];start(&t,b);for(int flag=1;flag;flag=0) {finish(&t);continue;} }
void skip(void) { int t;for(;0;finish(&t)) {finish(&t);} }
void precondition(void) { int t;for(;;) {finish(&t);break;} }
void break_skip(void) { int t;for(;;finish(&t)) {break;} }
void return_skip(void) { int t;for(;;finish(&t)) {return;} }
void continue_checks(void) { int t;for(;;finish(&t)) {continue;} }
void abandoned(void) { int t;char b[16];for(start(&t,b);;finish(&t)) {break;} }
void early(void) { int t;char b[16];for(start(&t,b);;finish(&t)) {return;} }
void expired(void) { int t;for(;;poll(&t)) {char b[16];start(&t,b);} }
void conflict(void) { int t;char b[16];for(start(&t,b);poll(&t);) {b[0]=1;} }
void repeated(int flag) { int t;char b[16];for(;flag;) {start(&t,b);finish(&t);} }
void nested(void) { int t;char b[16];for(;;) {for(start(&t,b);poll(&t);) {continue;}break;} }
int check(int *t) { return poll(t); }
void helper(void) { int t;char b[16];for(start(&t,b);check(&t);) {} }
int memory_good(void) { char b[16];char *p;for(p=b;;) {break;}return p[15]; }
int memory_bad(void) { char b[16];char *p=b;for(int flag=1;flag;p=b+16) {if(p==b+16) break;flag=0;}return *p; }
int condition_bad(void) { char b[16];char *p=b+16;for(;*p;) {} return 0; }
int memory_continue(void) { char b[16];char *p=b;for(int flag=1;flag;p=b+16) {flag=0;continue;}return *p; }
int memory_break(void) { char b[16];char *p=b;for(;;p=b+16) {break;}return *p; }
int memory_return(void) { char b[16];char *p=b;for(;;p=b+16) {return *p;} }
int scoped(void) { char *p;for(char b[16];;) {p=b;break;}return *p; }
int counter(void) { int x=0;for(int i=0;i<3;i++) {x=1;}return x; }
#define LOOP for(;;)
int macro_loop(void) { LOOP {return 0;} }
