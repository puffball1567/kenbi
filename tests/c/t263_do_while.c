/* Independently authored do-while state, lifetime and access regressions. */
extern void start(int *, const void *);
extern void finish(int *);
extern int poll(int *);
void good(void) { int t; char b[16]; start(&t,b); do {} while(poll(&t)); }
void continued(void) { int t; char b[16]; start(&t,b); do {continue;} while(poll(&t)); }
void once(void) { int t; char b[16]; do {start(&t,b);finish(&t);} while(0); }
void first_required(void) { int t; char b[16]; do {start(&t,b);} while(0); finish(&t); }
void precondition(void) { int t; do {finish(&t);} while(0); }
void restart(int flag) { int t; char b[16]; do {start(&t,b);} while(flag); finish(&t); }
void abandoned(void) { int t; char b[16]; do {start(&t,b);break;} while(poll(&t)); }
void early(void) { int t; char b[16]; do {start(&t,b);return;} while(poll(&t)); }
void break_skip(void) { int t; do {break;} while(poll(&t)); }
void return_skip(void) { int t; do {return;} while(poll(&t)); }
void continue_checks(void) { int t; do {continue;} while(poll(&t)); }
void expired(void) { int t; do {char b[16];start(&t,b);} while(poll(&t)); }
void conflict(void) { int t; char b[16]; start(&t,b); do {b[0]=1;} while(poll(&t)); }
void repeated(int flag) { int t; char b[16]; do {start(&t,b);finish(&t);} while(flag); }
void nested(void) { int t; char b[16]; do {start(&t,b);do {continue;} while(poll(&t));break;} while(1); }
int check(int *t) { return poll(t); }
void helper(void) { int t; char b[16]; start(&t,b);do {} while(check(&t)); }
int memory_good(void) { char b[16];char *p;do {p=b;} while(0);return p[15]; }
int memory_bad(void) { char b[16];char *p=b;do {p=b+16;} while(0);return *p; }
int condition_bad(void) { char b[16];char *p=b+16;do {} while(*p);return 0; }
int memory_continue(void) { char b[16];char *p=b+16;do {continue;} while(*p);return 0; }
int memory_break(void) { char b[16];char *p=b+16;do {break;} while(*p);return 0; }
int memory_return(void) { char b[16];char *p=b+16;do {return 0;} while(*p); }
