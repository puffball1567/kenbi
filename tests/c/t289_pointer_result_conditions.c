/* Deliberate out-of-range accesses exercise Kenbi diagnostics. */
#pragma clang diagnostic ignored "-Warray-bounds"
/* Independently authored pointer-result condition regression inputs. */
char*identity(char*p) { return p; }
char*none(void) { return 0; }
int good(void) { char a[4];if(identity(a))return a[3];return a[4]; }
int null_skip(void) { char a[4];if(none())return a[4];return 0; }
int negated(void) { char a[4];if(!identity(a))return a[4];return 0; }
int double_negated(void) { char a[4];if(!!none())return a[4];return 0; }
int bad(void) { char a[4];if(identity(a))return a[4];return 0; }
int null_bad(void) { char a[4];if(!none())return a[4];return 0; }
int conjunction(void) { char a[4];return none() && a[4]; }
int disjunction(void) { char a[4];return identity(a) || a[4]; }
int and_bad(void) { char a[4];return identity(a) && a[4]; }
int chosen(int flag) { char a[4];if(flag?identity(a):identity(a))return a[3];return a[4]; }
int chosen_null(int flag) { char a[4];if(!(flag?none():none()))return 0;return a[4]; }
int mixed_bad(int flag) { char a[4];if(flag?identity(a):none())return 0;return a[4]; }
int assigned(void) { char a[4];int yes=!none();if(yes)return 0;return a[4]; }
int truth(void) { return !none(); }
int relayed(void) { char a[4];if(truth())return 0;return a[4]; }
int loop(void) { char a[4];while(none())return a[4];return 0; }
extern char*view(char*);
int nullable_bad(void) { char a[4];if(view(a))return 0;return a[4]; }
int nullable_good(void) { char a[4];if(!view(a))return 0;return a[3]; }
int repeat_bad(void) { char a[4];if(!view(a))return 0;if(view(a))return 0;return a[4]; }
int unknown(char*p) { char a[4];if(identity(p))return 0;return a[4]; }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*begin_null(int*d,char*p) { start(d,p);return 0; }
void transfer(void) { int d;char a[4];if(begin(&d,a))finish(&d); }
void null_transfer(void) { int d;char a[4];if(!begin_null(&d,a))finish(&d); }
void selected_transfer(int flag) { int d;char a[4];if(flag?begin(&d,a):none())finish(&d); }
void short_transfer(void) { int d;char a[4];if(none() || begin(&d,a))finish(&d); }
void leak(void) { int d;char a[4];if(!begin(&d,a))finish(&d); }
int conflict(void) { int d;char a[4];int n=begin(&d,a) && a[0];finish(&d);return n; }
int expired(void) { char*p;{char a[4];p=a;}if(identity(p))return 0;return 1; }
int one_past(void) { char a[4];if(identity(a+4))return 0;return a[4]; }
int conditional_negated(int flag) { char a[4];if(!(flag?identity(a):identity(a)))return a[4];return 0; }
