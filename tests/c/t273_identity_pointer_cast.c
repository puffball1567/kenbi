/* Independently authored identity pointer conversion regression inputs. */
typedef char *Buffer;
int identity(void) { char a[8];char*p=a;char*q=(char*)p;return q[7]; }
int typedef_identity(void) { char a[8];Buffer p=a;Buffer q=(Buffer)p;return q[7]; }
int nested(void) { char a[8];char*p=a;return ((char*)(char*)p)[7]; }
int array_decay(void) { char a[8];char*p=(char*)a;return p[7]; }
int bad_range(void) { char a[8];char*p=a;return ((char*)p)[8]; }
int offset(void) { char a[8];char*p=a+7;return ((char*)p)[0]; }
int bad_offset(void) { char a[8];char*p=a+7;return ((char*)p)[1]; }
void expired(void) { char*p;{char a[8];p=a;}char*q=(char*)p; }
void unused(char*p) {}
void unused_expired(void) { char*p;{char a[8];p=a;}unused((char*)p); }
int helper(char*p) { return ((char*)p)[1]; }
int called(void) { char a[8];return helper((char*)(a+6)); }
int called_bad(void) { char a[8];return helper((char*)(a+7)); }
void rebind(void) { char*p;{char a[8];p=a;}char b[8];p=(char*)b;unused(p); }
int readonly(void) { const int a=1;const int*p=&a;return *((const int*)p); }
int null_read(void) { char*p=0;return *((char*)p); }
int reinterpret(void) { char a[8];char*p=a;int*q=(int*)p;return *q; }
void integer_pointer(unsigned long address) { char*p=(char*)address;unused(p); }
unsigned long pointer_integer(char*p) { return (unsigned long)p; }
void remove_const(const char*p) { char*q=(char*)p;unused(q); }
void void_pointer(void*p) { char*q=(char*)p;unused(q); }
void void_to_int(void*p) { int*q=(int*)p;(void)q; }
void void_remove_const(const void*p) { char*q=(char*)p;unused(q); }
void function_pointer(void(*p)(void)) { void(*q)(void)=(void(*)(void))p;q(); }
int volatile_pointer(volatile int*p) { return *((volatile int*)p); }
extern void consume(const void*);
void access_good(void) { _Alignas(16) char a[16];char*p=a;consume((char*)p); }
void access_small(void) { _Alignas(16) char a[4];char*p=a;consume((char*)p); }
void access_alignment(void) { _Alignas(16) char a[16];char*p=a+1;consume((char*)p); }
void access_const(void) { _Alignas(16) const char a[16]={0};const char*p=a;consume((const char*)p); }
extern void start(int*,char*);
extern void finish(int*);
int loan_conflict(void) { int d;char a[8];char*p=a;start(&d,(char*)p);int value=((char*)p)[0];finish(&d);return value; }
int loan_finished(void) { int d;char a[8];char*p=a;start(&d,(char*)p);finish(&d);return ((char*)p)[0]; }
