#include <stdlib.h>
// PROVABLY-CONSTANT STATICS fold in conditions. A file-scope `static` integer that nothing in
// the translation unit assigns, increments or takes the address of IS its initialiser (static
// linkage: invisible outside the TU), and a `static` function whose whole body is
// `return <const>;` is that constant — so `if (staticFive == 5)` / `if (staticReturnsTrue())`
// select one branch (the Juliet 05 / 07 / 08 shapes). A static that IS written anywhere, or an
// extern, stays a runtime branch — default-red.

static int staticFive = 5;
static int staticTrue = 1;
static int mutableFlag = 1;
static int staticReturnsTrue(void) { return 1; }
static int staticReturnsFalse(void) { return 0; }
void set_flag(void) { mutableFlag = 0; }

// @borrows(s)
void use(char *s);

// allocated under `staticFive == 5`, freed under `staticFive != 5` else-branch -> clean
static void folded_ok(void) {
  char *data = NULL;
  if (staticFive == 5) {
    /* @mem t::a { free: free, owner: data } */
    data = malloc(8);
  }
  if (staticFive != 5) {
    use("benign");
  } else {
    free(data);
  }
}

// the free is under a branch the folded static function never takes -> leak
static void folded_leak(void) {
  char *data = NULL;
  if (staticTrue) {
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
  }
  if (!staticReturnsTrue()) {
    free(data);
  }
}

// a static that is written somewhere in the TU is NOT folded: both branches stay possible
static void not_folded(void) {
  char *data = NULL;
  if (mutableFlag) {
    /* @mem t::c { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
  }
  if (!mutableFlag) {
    free(data);
  }
}

// both folded conditions agree -> clean
static void fn_fold_ok(void) {
  char *data = NULL;
  if (staticReturnsTrue()) {
    /* @mem t::d { free: free, owner: data } */
    data = malloc(8);
  }
  if (staticReturnsFalse()) {
    use("benign");
  } else {
    free(data);
  }
}
