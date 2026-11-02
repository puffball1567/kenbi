/* Independently authored external-access capacity regression inputs. */
extern void consume(const void *);
extern void unknown_api(void);
void helper(const void *p) { consume(p); }
void good(void) { char b[16]; consume(b); }
void small(void) { char b[7]; consume(b); }
void exact_offset(void) { char b[16]; consume(b+8); }
void short_offset(void) { char b[16]; consume(b+9); }
void one_past(void) { char b[16]; consume(b+16); }
void outside(void) { char b[16]; consume(b+17); }
void dynamic(int n) { char b[16]; consume(b+n); }
void unknown(const void *p) { consume(p); }
void alias(void) { char b[16]; char *p=b+9; helper(p); }
void helper_good(void) { char b[16]; helper(b+8); }
void readonly(void) { const char b[16]; consume(b); }
void branches(int n) { char b[16]; char c[7]; if(n) consume(b); else consume(c); }
void loop(int n) { char b[16]; while(n) consume(b); }
void unknown_call(void) { char b[16]; unknown_api(); consume(b); }
