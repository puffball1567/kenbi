/* Independently authored repeated automatic-lifetime regressions. */
void stale_do(int again) { int phase=0;char *p;do {char b[16];if(phase) *p=1;else p=b;phase=1;} while(again); }
void fresh_do(int again) { char *p;do {char b[16];p=b;*p=1;} while(again); }
void stale_while(int again) { int phase=0;char *p;while(again) {char b[16];if(phase) *p=1;else p=b;phase=1;} }
void fresh_while(int again) { char *p;while(again) {char b[16];p=b;*p=1;} }
void stale_for(int again) { int phase=0;char *p;for(;again;) {char b[16];if(phase) *p=1;else p=b;phase=1;} }
void fresh_for(int again) { char *p;for(;again;) {char b[16];p=b;*p=1;} }
void stale_alias(int again) { int phase=0;char *p;char *q;do {char b[16];if(phase) *q=1;else {p=b;q=p;}phase=1;} while(again); }
void stale_offset(int again) { int phase=0;char *p;do {char b[16];if(phase) *p=1;else p=b+8;phase=1;} while(again); }
void stale_continue(int again) { int phase=0;char *p;do {char b[16];if(phase) *p=1;else p=b;phase=1;continue;} while(again); }
void fresh_other(int again) { char a[16];char *p=a;do {char b[16];b[0]=1;*p=1;} while(again); }
void old_after_rebind(int again) { int phase=0;char *p;char *old;do {char b[16];if(phase) {old=p;p=b;*old=1;}else p=b;phase=1;} while(again); }
void write_helper(char *p) { *p=1; }
void stale_helper(int again) { int phase=0;char *p;do {char b[16];if(phase) write_helper(p);else p=b;phase=1;} while(again); }
extern void consume(const void *);
void stale_api(int again) { int phase=0;char *p;do {char b[16];if(phase) consume(p);else p=b;phase=1;} while(again); }
extern void start(int *,const void *);
extern void finish(int *);
void stale_resource(int again) { int phase=0;int *p;char b[16];do {int t;if(phase) {start(p,b);finish(p);}else p=&t;phase=1;} while(again); }
void stale_loan(int again) { int phase=0;char *p;int t;do {char b[16];if(phase) {start(&t,p);finish(&t);}else p=b;phase=1;} while(again); }
