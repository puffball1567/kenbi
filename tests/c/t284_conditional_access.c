/* Independently authored conditional scalar access regression inputs. */
int null_yes(void) { char*p=0;return p?*p:0; }
int null_no(void) { char*p=0;return !p?0:*p; }
int null_bad(void) { char*p=0;return !p?*p:0; }
int live(void) { char a[8];char*p=a;return p?p[7]:0; }
int range(void) { char a[8];char*p=a;return p?p[8]:0; }
int unknown(char*p) { return p?*p:0; }
int nested(void) { char a[8];char*p=a;char*q=0;return p?(q?*q:p[7]):0; }
int condition_bad(void) { char*p=0;return *p?1:2; }
int scalar_result(void) { char*p=0;int n=p?1:0;if(n)return *p;return 0; }
int scalar_bad(void) { char*p=0;int n=p?0:1;if(n)return *p;return 0; }
int same_result(int flag) { char*p=0;int n=flag?0:0;if(n)return *p;return 0; }
int branch_result(int flag) { char*p=0;int n=flag?0:1;if(n)return *p;return 0; }
int loop(void) { char*p=0;while(p?*p:0){}return 0; }
int do_loop(void) { char*p=0;do{}while(p?*p:0);return 0; }
int for_loop(void) { char*p=0;for(;p?*p:0;){}return 0; }
int pointer_arm(void) { char a[8];char*p=a;char*q=p?p:0;return *q; }
int update_arm(int flag) { int n=0;return flag?n++:0; }
extern int called(void);
int call_arm(int flag) { return flag?called():0; }
extern char*view(char*);
int nullable(void) { char a[8];char*p=view(a);return p?p[7]:0; }
int nullable_bad(void) { char a[8];char*p=view(a);return p?p[8]:0; }
int short_circuit(void) { char a[8];char*p=view(a);return (p&&p[0])?p[7]:0; }
extern void start(int*,char*);
extern void finish(int*);
int loan_skipped(void) { int d;char a[8];char*p=0;start(&d,a);int n=p?a[0]:0;finish(&d);return n; }
int loan_read(void) { int d;char a[8];char*p=a;start(&d,a);int n=p?a[0]:0;finish(&d);return n; }
