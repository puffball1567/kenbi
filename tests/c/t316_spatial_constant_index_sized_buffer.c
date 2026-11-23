// @spatial
// A CONSTANT INDEX INTO A BUFFER OF VARIABLE SIZE. `buf[0]` on `malloc(n * …)` is in range only
// if `n >= 1`, and nothing in the access says so. It is covered once the size is shown large
// enough: by a check on the path, or by a declared `@invariant(n >= K)`. The declaration is
// what the function assumes of its parameter, so it is verified where the function is called:
// every call must pass a value shown `>= K`.
#include <stdlib.h>
#include <string.h>
unsigned read_count(void);

// nothing shows the buffer holds an element
// @spatial
int first_unchecked(unsigned n) {
  /* @mem t::a { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = buf[0];                               //EXPECT UNVALIDATED_INDEX
  free(buf);
  return r;
}

// a check that does not reach the index used
// @spatial
int check_too_small(unsigned n) {
  /* @mem t::b { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (n >= 2) r = buf[2];                       //EXPECT UNVALIDATED_INDEX
  free(buf);
  return r;
}

// a constant length into a counted buffer
// @spatial
// @counted_by(dst: n)
void fixed_length(char *dst, unsigned n, const char *src) {
  memcpy(dst, src, 4);                          //EXPECT UNVALIDATED_SIZE
}

// the size checked on the path, in each of its forms — clean
// @spatial
int size_checked(unsigned n) {
  /* @mem t::c { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (n >= 4) r += buf[3];
  if (n > 0) r += buf[0];
  if (n != 0) r += buf[0];
  if (n == 0) { free(buf); return 0; }
  r += buf[0];
  free(buf);
  return r;
}

// the size declared: covers what it states, and no more
// @spatial
// @invariant(n >= 2)
int size_declared(unsigned n) {
  /* @mem t::d { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = buf[0] + buf[1];
  r += buf[2];                                  //EXPECT UNVALIDATED_INDEX
  free(buf);
  return r;
}

// the declaration is verified at each call
// @spatial
int calls(unsigned a) {
  int r = size_declared(4);
  r += size_declared(1);                        //EXPECT INVARIANT_NOT_MAINTAINED
  r += size_declared(a);                        //EXPECT INVARIANT_NOT_MAINTAINED
  r += size_declared(read_count());             //EXPECT INVARIANT_NOT_MAINTAINED
  if (a >= 2) r += size_declared(a);
  if (a >= 3) r += size_declared(a - 1);
  return r;
}
