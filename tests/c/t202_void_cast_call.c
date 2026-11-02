#include <stdlib.h>
// `(void) f(p);` IS A CALL. C's way of saying "I deliberately discard this result" is used on
// nearly every call in some codebases (ImageMagick writes it almost everywhere). The statement
// was dropped whole, so a declared contract on that call never applied: the release below read
// as the only one and the double free was MISSED. The discard is explicit, so it is not an
// UNUSED_MUST_USE finding either.

// @frees(p)
void take(char *p);
// @borrows(p)
void look(char *p);
// @must_use
int check(void);

// the contract applies through the cast
static void released_twice(void) {
  /* @mem d::a { free: free, owner: p } */
  char *p = malloc(8);
  (void) take(p);
  free(p);   //EXPECT DOUBLE_FREE
}

// ... and a borrow through the cast is still just a use
static void borrowed(void) {
  /* @mem d::b { free: free, owner: p } */
  char *p = malloc(8);
  (void) look(p);
  free(p);
}

// ... and the use after the release is caught
static void used_after(void) {
  /* @mem d::c { free: free, owner: p } */
  char *p = malloc(8);
  (void) take(p);
  look(p);   //EXPECT USE_AFTER_FREE
}

// an explicit `(void)` discard of a @must_use result is deliberate, not a finding
static void deliberate_discard(void) {
  (void) check();
}

// ... while dropping it silently still is
static void silent_discard(void) {
  check();   //EXPECT UNUSED_MUST_USE
}
