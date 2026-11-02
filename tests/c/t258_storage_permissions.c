/* Independently authored storage-permission regressions. */
struct Transfer { int state; };
extern void start(struct Transfer *, const void *);
extern void finish(struct Transfer *);
extern void modify(const void *);
void helper(struct Transfer *t, const void *p) { start(t,p); finish(t); }
void immutable(void) { struct Transfer t; const char b[16]; helper(&t,b); }
void immutable_alias(void) { struct Transfer t; const char b[16]; const char *p=b; helper(&t,p); }
void immutable_offset(void) { struct Transfer t; const char b[16]; helper(&t,b+1); }
void initialized(void) { struct Transfer t; const int b=1; helper(&t,&b); }
void parameter(const int b) { struct Transfer t; helper(&t,&b); }
void mutable_view(void) { struct Transfer t; char b[16]; const char *p=b; helper(&t,p); }
void const_pointer(void) { struct Transfer t; char b[16]; char * const p=b; helper(&t,p); }
void external_write(void) { struct Transfer t; const char b[16]; helper(&t,b); modify(b); }
void external_alias(void) { const char b[16]; const char *p=b; modify(p); }
void external_mutable(void) { char b[16]; const char *p=b; modify(p); }
void copy(int value) { struct Transfer t; helper(&t,&value); }
void mutable_copy(void) { const int value=1; copy(value); }
struct Partial { const int a; int b; };
void partial(void) { struct Transfer t; struct Partial b; helper(&t,&b); }
typedef const char Readonly[16];
void typedef_array(void) { struct Transfer t; Readonly b; helper(&t,b); }
void nested_array(void) { struct Transfer t; const char b[2][8]; helper(&t,b); }
void branches(int flag) { struct Transfer t; char b[16]; const char c[16]; if(flag) helper(&t,b); else helper(&t,c); }
void loop(int flag) { struct Transfer t; while(flag) { const int b=1; helper(&t,&b); } }
extern void const_start(const struct Transfer *, const void *);
extern void const_finish(const struct Transfer *);
void immutable_handle(void) { const struct Transfer t; char b[16]; const_start(&t,b); const_finish(&t); }
