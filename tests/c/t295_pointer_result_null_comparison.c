/* Deliberate bad accesses exercise Kenbi, not Clang's warning. */
#pragma clang diagnostic ignored "-Warray-bounds"
/* Independently authored returned-pointer/null comparison checks. */
char*identity(char*p) { return p; }
char*none(void) { return 0; }
int good(void) { char a[4];if(identity(a)!=0)return 0;return a[4]; }
int equal(void) { char a[4];if(none()==0)return 0;return a[4]; }
int reversed(void) { char a[4];if(0!=identity(a))return 0;return a[4]; }
int reversed_equal(void) { char a[4];if(0==none())return 0;return a[4]; }
int negated(void) { char a[4];if(!(identity(a)==0))return 0;return a[4]; }
int assigned(void) { char a[4];int ok=none()==0;if(ok)return 0;return a[4]; }
int truth(void) { return none()==0; }
int relayed(void) { char a[4];if(truth())return 0;return a[4]; }
int chosen(int flag) { char a[4];if((flag?identity(a):identity(a))!=0)return 0;return a[4]; }
int arithmetic(void) { char a[4];if(identity(a)+4!=0)return 0;return a[4]; }
int loop(void) { char a[4];while(none()!=0)return a[4];return 0; }
int short_circuit(void) { char a[4];return (none()!=0)&&a[4]; }
int bad(void) { char a[4];if(identity(a)==0)return 0;return a[4]; }
int null_bad(void) { char a[4];if(none()!=0)return 0;return a[4]; }
int unknown(char*p) { char a[4];if(identity(p)!=0)return 0;return a[4]; }
int expired(void) { char*p;{char a[4];p=a;}return identity(p)!=0; }
extern char*view(char*);
int nullable_good(void) { char a[4];if(view(a)==0)return 0;return a[3]; }
int nullable_bad(void) { char a[4];if(view(a)!=0)return 0;return a[4]; }
int repeat_bad(void) { char a[4];if(view(a)==0)return 0;if(view(a)!=0)return 0;return a[4]; }
int two_calls(void) { char a[4];return identity(a)==none(); }
int ordering(void) { char a[4];return identity(a)<none(); }
extern void start(int*,char*);
extern void finish(int*);
char*begin(int*d,char*p) { start(d,p);return p; }
char*begin_null(int*d,char*p) { start(d,p);return 0; }
void transfer(void) { int d;char a[4];if(begin(&d,a)!=0)finish(&d); }
void null_transfer(void) { int d;char a[4];if(0==begin_null(&d,a))finish(&d); }
void selected_transfer(int flag) { int d;char a[4];if((flag?begin(&d,a):none())!=0)finish(&d); }
void leak(void) { int d;char a[4];if(begin(&d,a)==0)finish(&d); }
int conflict(void) { int d;char a[4];int n=(begin(&d,a)!=0)&&a[0];finish(&d);return n; }
