/* Independently authored function-exit lifetime regression inputs. */
#pragma clang diagnostic ignored "-Wreturn-stack-address"
char* local(void) { char a[8];return a; } //EXPECT DANGLING_RETURN
char* alias(void) { char a[8];char*p=a;return p; } //EXPECT DANGLING_RETURN
char* offset(void) { char a[8];char*p=a+1;return p; }
char* nested(void) { {char a[8];char*p=a;return p;} } //EXPECT DANGLING_RETURN
int* parameter(int value) { return &value; }
char* expired(void) { char*p;{char a[8];p=a;}return p; } //EXPECT DANGLING_RETURN
char* null_return(void) { return 0; }
char* unknown(char*p) { return p; }
char* branch(int flag) { char a[8];if(flag)return a;return 0; } //EXPECT DANGLING_RETURN
char* dead_branch(void) { if(0){char a[8];return a;}return 0; }
char* pass(char*p) { return p; }
void called_good(void) { char a[8];pass(a); }
void called_bad(void) { local(); }
char* loop(int flag) { while(flag){char a[8];return a;}return 0; } //EXPECT DANGLING_RETURN
char* cast_local(void) { char a[8];char*p=a;return (char*)p; } //EXPECT DANGLING_RETURN
