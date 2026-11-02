/* Independently authored sequenced short-circuit call regression inputs. */
int zero(void) { return 0; }
int one(void) { return 1; }
int read_bad(char*p) { return p[8]; }
int read_good(char*p) { return p[7]; }
int good_and(void) { char a[8];return one()&&read_good(a); }
int good_or(void) { char a[8];return zero()||read_good(a); }
int skip_and(void) { char a[8];return zero()&&read_bad(a); }
int skip_or(void) { char a[8];return one()||read_bad(a); }
int bad_and(void) { char a[8];return one()&&read_bad(a); }
int bad_or(void) { char a[8];return zero()||read_bad(a); }
int nested(void) { char a[8];return (one()&&zero())||read_good(a); }
int guarded(void) { char*p=0;int r=one()&&zero();if(r)return *p;return 0; }
int wrong_guard(void) { char*p=0;int r=zero()||one();if(r)return *p;return 0; }
int loop(void) { while(one()&&zero()){}return 0; }
int do_loop(void) { do{}while(one()&&zero());return 0; }
int for_loop(void) { for(;one()&&zero();){}return 0; }
extern void start(int*,char*);
extern void finish(int*);
int begin(int*d,char*p) { start(d,p);return 1; }
int end(int*d) { finish(d);return 1; }
void transfer(void) { int d;char a[8];begin(&d,a)&&end(&d); }
void transfer_or(void) { int d;char a[8];int r=begin(&d,a)&&0;int done=r||end(&d); }
void leak(void) { int d;char a[8];begin(&d,a)||end(&d); }
void wrong_end(void) { int d;char a[8];zero()||end(&d); }
void borrowed_read(void) { int d;char a[8];int r=begin(&d,a)&&read_good(a);finish(&d); }
void skipped_read(void) { int d;char a[8];int r=begin(&d,a)||read_good(a);finish(&d); }
