/* Independently authored pointer-value lifetime regression inputs. */
void copy_dead(void) { char*p;{char a[8];p=a;}char*q=p; }
void assign_dead(void) { char*p;{char a[8];p=a;}char*q=0;q=p; }
int negate_dead(void) { char*p;{char a[8];p=a;}return !p; }
int condition_dead(void) { char*p;{char a[8];p=a;}if(p)return 1;return 0; }
void unused(char*p) {}
void pass_dead(void) { char*p;{char a[8];p=a;}unused(p); }
void loop_dead(void) { char*p;{char a[8];p=a;}while(p){break;} }
void copy_live(void) { char a[8];char*p=a;char*q=p; }
void replace_dead(void) { char*p;{char a[8];p=a;}char b[8];p=b;char*q=p; }
void take_address(void) { char*p;{char a[8];p=a;}char**q=&p; }
int skip_dead(void) { char*p;{char a[8];p=a;}return 0&&!p; }
int skip_or(void) { char*p;{char a[8];p=a;}return 1||!p; }
int null_value(void) { char*p=0;return !p; }
int unknown_value(char*p) { return !p; }
void alias_dead(void) { char*p;char*q;{char a[8];p=a;q=p;}p=0;unused(q); }
void offset_dead(void) { char*p;{char a[8];p=a+1;}unused(p); }
