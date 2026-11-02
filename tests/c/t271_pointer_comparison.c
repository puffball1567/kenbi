/* Independently authored pointer-comparison gate regression inputs. */
int less(void) { char a[16],b[16];char*p=a;char*q=b;return p<q; }
int greater(void) { char a[16],b[16];char*p=a;char*q=b;return p>q; }
int less_equal(void) { char a[16],b[16];char*p=a;char*q=b;return p<=q; }
int greater_equal(void) { char a[16],b[16];char*p=a;char*q=b;return p>=q; }
int same(void) { char a[16];char*p=a;char*q=a+8;return p<q; }
int unknown(char*p,char*q) { return p<q; }
int equal(void) { char a[16],b[16];char*p=a;char*q=b;return p==q; }
int unequal(void) { char a[16],b[16];char*p=a;char*q=b;return p!=q; }
int null_check(char*p) { return p==0; }
int null_left(char*p) { return 0!=p; }
int expired(void) { char*p;{char a[16];p=a;}return p==0; }
int expired_order(void) { char*p;{char a[16];p=a;}char b[16];return p<b; }
int helper(char*p,char*q) { return p>=q; }
int called(void) { char a[16],b[16];return helper(a,b); }
int dead(void) { char a[16],b[16];char*p=a;char*q=b;return 0&&(p<q); }
int integer(int a,int b) { return a<b; }
