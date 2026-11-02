/* Independently authored null-pointer fact regression inputs. */
int direct(void) { char*p=0;return *p; }
int copied(void) { char*p=0;char*q=p;return *q; }
int assigned(void) { char a[8];char*p=a;p=0;return *p; }
int alias(void) { char*p=0;char*q=p;char a[8];p=a;return *q; }
int rebound(void) { char*p=0;char a[8];p=a;return p[7]; }
void arithmetic(void) { char*p=0;p+=0; }
void increment(void) { char*p=0;p++; }
char* null_helper(void) { char*p=0;return p; }
int returned(void) { char*p=null_helper();return *p; }
int guarded(void) { char*p=null_helper();if(p)return *p;return 0; }
int guarded_eq(void) { char*p=0;if(p==0)return 0;return *p; }
int guarded_not(void) { char*p=0;if(!p)return 0;return *p; }
int guarded_ne(void) { char*p=0;if(p!=0)return *p;return 0; }
int known_live(void) { char a[8];char*p=a;if(p)return p[7];char*q=0;return *q; }
int helper(char*p) { if(!p)return 0;return *p; }
int called(void) { return helper(0); }
int helper_bad(char*p) { return *p; }
int called_bad(void) { return helper_bad(0); }
int scope(void) { char a[8];char*p=a;{char*q=0;p=q;}return *p; }
int shadow(void) { char a[8];char*p=a;{char*p=0;if(p)return *p;}return *p; }
int branch(int flag) { char a[8];char*p=a;if(flag)p=0;return *p; }
int loop(void) { char a[8];char*p=a;do{p=0;}while(0);return *p; }
int unknown(char*p) { if(!p)return 0;return *p; }
char*relay(char*p) { return p; }
int relay_null(void) { char*p=relay(0);return *p; }
