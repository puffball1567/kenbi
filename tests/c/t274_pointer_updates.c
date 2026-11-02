/* Independently authored standalone pointer update regression inputs. */
int post(void) { char a[4];char*p=a;p++;return *p; }
int pre(void) { char a[4];char*p=a;++p;return *p; }
int down(void) { char a[4];char*p=a+4;p--;--p;return *p; }
int plus(void) { int a[4];int*p=a;p+=3;return *p; }
int minus(void) { int a[4];int*p=a+4;p-=4;return *p; }
void one_past(void) { char a[1];char*p=a;++p; }
int end_read(void) { char a[1];char*p=a;p++;return *p; }
void past(void) { char a[1];char*p=a;p++;p++; }
void before(void) { char a[1];char*p=a;p--; }
void restored(void) { char a[4];char*p=a;p+=5;p-=5; }
void negative(void) { char a[4];char*p=a;p+=-1; }
int negative_minus(void) { char a[4];char*p=a;p-=-1;return *p; }
void dynamic(int n) { char a[4];char*p=a;p+=n; }
void unknown(char*p) { p++; }
void expired(void) { char*p;{char a[4];p=a;}p++; }
int alias(void) { char a[4];char*p=a;char*q=p;p+=4;return *q; }
int block(void) { char a[4];char*p=a;{p+=4;}return *p; }
int helper(char*p) { p++;return *p; }
int called(void) { char a[4];return helper(a+2); }
int called_bad(void) { char a[4];return helper(a+3); }
void for_good(void) { char a[4];for(char*p=a;;p++){break;} }
void for_bad(int flag) { char a[1];for(char*p=a;flag;p++){continue;} }
void volatile_pointer(void) { char a[4];char*volatile p=a;p++; }
int expression_update(void) { char a[4];char*p=a;return *p++; }
extern int amount(void);
void call_update(void) { char a[4];char*p=a;p+=amount(); }
#define ADVANCE(p) (++(p))
void macro_update(void) { char a[4];char*p=a;ADVANCE(p); }
extern void start(int*,char*);
extern void finish(int*);
void loan_move(void) { int d;char a[4];char*p=a;start(&d,p);p++;finish(&d); }
int loan_read(void) { int d;char a[4];char*p=a;start(&d,p);p++;int v=*p;finish(&d);return v; }
void zero(void) { char a[4];char*p=a;p+=0;p-=0; }
int typed_down(void) { int a[4];int*p=a+4;p--;return *p; }
void minus_before(void) { int a[4];int*p=a;p-=1; }
void huge(void) { char a[4];char*p=a;p+=1000000; }
void null_update(void) { char*p=0;p++; }
