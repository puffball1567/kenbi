/* Independently authored path-sensitive short-circuit access inputs. */
int null_and(void) { char*p=0;return p&&*p; }
int null_or(void) { char*p=0;return !p||*p; }
int null_eq(void) { char*p=0;return p==0||p[0]; }
int null_bad_and(void) { char*p=0;return !p&&*p; }
int null_bad_or(void) { char*p=0;return p||*p; }
int live_and(void) { char a[8];char*p=a;return p&&p[7]; }
int live_or(void) { char a[8];char*p=a;return !p||p[7]; }
int range_and(void) { char a[8];char*p=a;return p&&p[8]; }
int range_or(void) { char a[8];char*p=a;return !p||p[8]; }
int nested(void) { char a[8];char*p=a;char*q=0;return (p&&p[7])||(!q||*q); }
int unknown(char*p) { return p&&*p; }
int expired(void) { char*p;{char a[8];p=a;}return p&&*p; }
int helper(char*p) { return !p||*p; }
int called(void) { return helper(0); }
int loop(void) { char*p=0;while(p&&*p){}return 0; }
int do_loop(void) { char*p=0;do{}while(p&&*p);return 0; }
int for_loop(void) { char*p=0;for(;p&&*p;){}return 0; }
extern char*view(char*);
int nullable(void) { char a[8];char*p=view(a);return p&&p[7]; }
int nullable_bad(void) { char a[8];char*p=view(a);return p&&p[8]; }
int nullable_or(void) { char a[8];char*p=view(a);return !p||p[7]; }
extern void start(int*,char*);
extern void finish(int*);
int loan_skipped(void) { int d;char a[8];char*p=0;start(&d,a);int n=p&&a[0];finish(&d);return n; }
int loan_read(void) { int d;char a[8];char*p=a;start(&d,a);int n=p&&a[0];finish(&d);return n; }
int evaluated_left(void) { char*p=0;return *p&&0; }
