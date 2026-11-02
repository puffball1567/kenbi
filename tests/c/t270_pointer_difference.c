/* Independently authored pointer-difference gate regressions. */
void unrelated(void) { char a[16],b[16];long n=a-b; }
void aliases(void) { char a[16],b[16];char*p=a;char*q=b;long n=p-q; }
void same(void) { char a[16];long n=(a+8)-a; }
void identical(void) { char a[16];long n=a-a; }
void unknown(char*p,char*q) { long n=p-q; }
void null_difference(void) { char*p=0;char*q=0;long n=p-q; }
void expired(void) { char*p;{char a[16];p=a;}char b[16];long n=p-b; }
void helper(char*p,char*q) { long n=p-q; }
void called(void) { char a[16],b[16];helper(a,b); }
void same_called(void) { char a[16];helper(a+8,a); }
void unused(long n) { }
void unused_argument(void) { char a[16],b[16];unused(a-b); }
int comparison(void) { char a[16],b[16];return (a-b)==0; }
int dead(void) { char a[16],b[16];return 0 && ((a-b)==0); }
