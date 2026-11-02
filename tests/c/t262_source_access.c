/* Independently authored source memory-access regressions. */
int good(void) { char b[16]; b[15]=1; return b[15]; }
int typed(void) { int b[4]; b[3]=1; return b[3]; }
int bad_read(void) { char b[16]; char *p=b; return p[16]; }
void bad_write(void) { char b[16]; char *p=b; p[16]=1; }
int before(void) { char b[16]; return *(b-1); }
int one_past(void) { char b[16]; char *p=b+16; return *p; }
int dynamic(int n) { char b[16]; return b[n]; }
int unknown(char *p) { return *p; }
int alias(void) { char b[16]; char *p=b+8; return p[7]; }
int alias_bad(void) { char b[16]; char *p=b+8; return p[8]; }
int helper(char *p) { return p[1]; }
int called(void) { char b[16]; return helper(b+14); }
int called_bad(void) { char b[16]; return helper(b+15); }
int block(void) { char b[16]; char *p=b; {p=b+16;} return *p; }
int escaped(void) { char *p; {char b[16]; p=b;} return *p; }
int branches(int flag) { char b[16]; char *p=b; if(flag) return p[15]; else return p[16]; }
int loop(int flag) { char b[16]; char *p=b; while(flag) {p=b+16;break;} return *p; }
int scalar(int value) { int x=value; return x; }
int global_value;
int global(void) { return global_value; }
int readonly(void) { const int x=1; return *(&x); }
int volatile_read(void) { volatile int x; return x; }
extern void external(void);
void missing_contract(void) { external(); }
int typed_bad(void) { int b[4]; int *p=b+3; return p[1]; }
int null_read(void) { char *p=0; return *p; }
int cast_read(void) { char b[16]; int *p=(int *)(b+1); return *p; }
int invalid_restored(void) { char b[16]; char *p=b+17; p=p-17; return *p; }
