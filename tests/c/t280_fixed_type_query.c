/* Independently authored fixed sizeof/alignof regression inputs. */
int sized(void) { char a[16];char*p=a+sizeof(int);return *p; }
int size_array(void) { char a[8];char*p=a+sizeof a;p--;return *p; }
int size_array_bad(void) { char a[8];char*p=a+sizeof a;return *p; }
int size_object(void) { int n=0;char a[16];char*p=a+sizeof n;return *p; }
int size_pointee(void) { int*p=0;char a[16];char*q=a+sizeof *p;return *q; }
int alignment(void) { char a[32];char*p=a+_Alignof(long double);return *p; }
void too_far(void) { char a[1];char*p=a+sizeof(long long); }
int plus_update(void) { char a[16];char*p=a;p+=sizeof(int);return *p; }
int minus_update(void) { char a[16];char*p=a+16;p-=sizeof(int);return *p; }
int indexed(void) { char a[16];return a[sizeof(int)]; }
int reverse(void) { char a[16];return (sizeof(int))[a]; }
int pointer_size(void) { char a[32];char*p=a+sizeof(void*);return *p; }
int query_expired(void) { int*p;{int a;p=&a;}return sizeof *p; }
int vla(int n) { int a[n];return sizeof a; }
int vla_type(int n) { return sizeof(int[n]); }
int hidden_vla(int n) { return sizeof(int(*)[n++]); }
extern int external(void);
int unevaluated_call(void) { return sizeof external(); }
#define SIZE sizeof(int)
int macro_query(void) { return SIZE; }
int expression_index(void) { char a[16];return a[sizeof(int)+1]; }
extern void start(int*,char*);
extern void finish(int*);
int loan_query(void) { int d;char a[8];start(&d,a);int n=sizeof a;finish(&d);return n; }
int loan_access(void) { int d;char a[8];start(&d,a);int n=a[sizeof(char)];finish(&d);return n; }
void target_size(void) { char a[4];char*p=a+sizeof(void*); }
int volatile_size(void) { volatile int n;return sizeof n; }
