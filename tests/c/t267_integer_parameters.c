/* Independently authored value-parameter storage regression inputs. */
extern void consume(const void *);
void char_arg(char n) { consume(&n); }
void signed_char_arg(signed char n) { consume(&n); }
void uchar_arg(unsigned char n) { consume(&n); }
void short_arg(short n) { consume(&n); }
void ushort_arg(unsigned short n) { consume(&n); }
void int_arg(int n) { consume(&n); }
void uint_arg(unsigned n) { consume(&n); }
void long_arg(long n) { consume(&n); }
void ulong_arg(unsigned long n) { consume(&n); }
void llong_arg(long long n) { consume(&n); }
void ullong_arg(unsigned long long n) { consume(&n); }
void bool_arg(_Bool n) { consume(&n); }
enum Flag { OFF, ON };
void enum_arg(enum Flag n) { consume(&n); }
typedef unsigned long Count;
void typedef_arg(Count n) { consume(&n); }
void const_arg(const unsigned n) { consume(&n); }
void alias_arg(unsigned n) { unsigned *p=&n;consume(p); }
void updated(unsigned n) { n++;consume(&n); }
void entry(void) { typedef_arg(7); }
void small(unsigned char n) { consume(&n); }
void float_arg(float n) { consume(&n); }
void narrowed(void) { int n=256;uchar_arg(n); }
extern void start(int *,const void *);
extern void finish(int *);
void retained(int *t,unsigned n) { start(t,&n); }
void completed(int *t,unsigned n) { start(t,&n);finish(t); }
void loan_bad(void) { int t;retained(&t,7);finish(&t); }
void loan_good(void) { int t;completed(&t,7); }
void copied_const(void) { const unsigned n=7;uint_arg(n); }
