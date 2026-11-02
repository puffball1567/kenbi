/* The library's declared interface: the contracts callers compile against. The same
   contracts appear on the definitions in lib.c — kenbi checks the bodies honour them. */
// @frees(p)
void lib_release(char *p);
// @owns
char *lib_make(int n);
// an external boundary: declared here, defined in no file this project analyses
// @frees(p)
void vendor_release(char *p);
