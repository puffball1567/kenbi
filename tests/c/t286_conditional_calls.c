/* Independently authored sequenced conditional call regression inputs. */
int zero(void) { return 0; }
int one(void) { return 1; }
int read_bad(char*p) { return p[8]; }
int read_good(char*p) { return p[7]; }
int good(void) { char a[8];return one()?read_good(a):read_bad(a); }
int bad(void) { char a[8];return zero()?read_good(a):read_bad(a); }
int branch(int flag) { char a[8];return flag?read_good(a):read_bad(a); }
int skipped(void) { char a[8];return 0?read_bad(a):0; }
int guarded(void) { char*p=0;int r=1?zero():one();if(r)return *p;return 0; }
int overwritten(void) { char*p=0;int r=zero()?zero():one();if(r)return *p;return 0; }
int assigned(void) { char*p=0;int r=1;r=one()?zero():one();if(r)return *p;return 0; }
int nested(void) { char a[8];return one()?(zero()?read_bad(a):read_good(a)):read_bad(a); }
int condition_bad(void) { char a[8];return read_bad(a)?0:1; }
int loop(void) { while(one()?zero():one()){}return 0; }
int do_loop(void) { do{}while(one()?zero():one());return 0; }
int for_loop(void) { for(;one()?zero():one();){}return 0; }
extern void start(int*,char*);
extern void finish(int*);
int begin(int*d,char*p) { start(d,p);return 0; }
int end(int*d) { finish(d);return 0; }
void transfer(int flag) { int d;char a[8];int r=flag?begin(&d,a):1;if(r==0)finish(&d); }
void wrong_end(int flag) { int d;char a[8];int r=flag?begin(&d,a):0;if(r==0)finish(&d); }
void leak(int flag) { int d;char a[8];int r=flag?begin(&d,a):1; }
void cleanup(void) { int d;char a[8];start(&d,a);int r=one()?end(&d):1; }
void condition_start(void) { int d;char a[8];int r=begin(&d,a)?1:end(&d); }
void condition_leak(void) { int d;char a[8];int r=begin(&d,a)?end(&d):1; }
