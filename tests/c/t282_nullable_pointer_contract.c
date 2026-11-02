/* Independently authored nullable borrowed-result contract inputs. */
extern char*view(char*);
int unguarded(void) { char a[8];char*p=view(a);return *p; }
int guarded(void) { char a[8];char*p=view(a);if(!p)return 0;return p[7]; }
int guarded_bad(void) { char a[8];char*p=view(a);if(!p)return 0;return p[8]; }
int equal(void) { char a[8];char*p=view(a);if(p==0)return 0;return *p; }
int unequal(void) { char a[8];char*p=view(a);if(p!=0)return *p;return 0; }
int null_branch(void) { char a[8];char*p=view(a);if(!p)return *p;return 0; }
int copied(void) { char a[8];char*p=view(a);char*q=p;if(q)return *q;return 0; }
int stale_guard(void) { char a[8];char*p=view(a);if(!p)return 0;p=view(a);return *p; }
int helper(char*p) { if(!p)return 0;return p[7]; }
int called(void) { char a[8];char*p=view(a);return helper(p); }
char*relay(char*p) { return view(p); }
int relayed(void) { char a[8];char*p=relay(a);if(p)return p[7];return 0; }
char*visible(char*p,int flag) { if(flag)return p;return 0; }
int visible_caller(int flag) { char a[8];char*p=visible(a,flag);if(p)return p[7];return 0; }
char*always_null(char*p) { return 0; }
int always_caller(void) { char a[8];char*p=always_null(a);if(p)return *p;return 0; }
char*wrong(char*p) { return p+1; }
int wrong_caller(void) { char a[8];char*p=wrong(a);if(p)return *p;return 0; }
int escaped(void) { char*p;{char a[8];p=view(a);}if(p)return *p;return 0; }
extern void start(int*,char*);
extern void finish(int*);
int loan_conflict(void) { int d;char a[8];start(&d,a);char*p=view(a);if(!p){finish(&d);return 0;}int v=*p;finish(&d);return v; }
int loan_good(void) { int d;char a[8];start(&d,a);char*p=view(a);finish(&d);if(p)return *p;return 0; }
int loan_leak(void) { int d;char a[8];start(&d,a);char*p=view(a);if(!p)return 0;finish(&d);return *p; }
