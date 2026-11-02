/* Independently authored commuted C pointer operation inputs. */
#pragma clang diagnostic ignored "-Warray-bounds"
int plus(void) { char a[8];char*p=1+a;return p[6]; }
int plus_bad(void) { char a[8];char*p=1+a;return p[7]; }
void formed_bad(void) { char a[8];char*p=9+a; }
int typed(void) { int a[4];int*p=1+a;return 2[p]; }
int typed_bad(void) { int a[4];int*p=1+a;return 3[p]; }
int indexed(void) { char a[8];return 7[a]; }
int indexed_bad(void) { char a[8];return 8[a]; }
void write(void) { char a[8];7[a]=1; }
void write_bad(void) { char a[8];8[a]=1; }
void address(void) { char a[8];char*p=&8[a]; }
void address_bad(void) { char a[8];char*p=&9[a]; }
int addressed(void) { char a[8];char*p=&7[a];return *p; }
int negative(void) { char a[8];char*p=a+1;return (-1)[p]; }
int negative_bad(void) { char a[8];char*p=a;return (-1)[p]; }
void dynamic(int n) { char a[8];char*p=n+a; }
int dynamic_index(int n) { char a[8];return n[a]; }
int expired(void) { char*p;{char a[8];p=a;}return 0[p]; }
int helper(char*p) { return 1[p]; }
int called(void) { char a[8];return helper(6+a); }
int called_bad(void) { char a[8];return helper(7+a); }
char* advanced(char*p) { return 1+p; }
int returned(void) { char a[8];char*p=advanced(a);return 7[p]; }
int nested(void) { char a[8];return 6[1+a]; }
int nested_bad(void) { char a[8];return 7[1+a]; }
extern void start(int*,char*);
extern void finish(int*);
void loan_address(void) { int d;char a[8];start(&d,a);char*p=&1[a];finish(&d); }
int loan_read(void) { int d;char a[8];start(&d,a);int v=1[a];finish(&d);return v; }
