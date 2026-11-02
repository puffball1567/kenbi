#include <stdlib.h>
// TESTING THE SAME UNCHANGING FLAG TWICE DOES NOT MEAN FOUR COMBINATIONS.
//
//     if (want) p = malloc(16);
//     if (want) free(p);
//
// A may-merge analysis considers the allocated-and-not-freed combination, which the program
// cannot produce: `want` is a local the function never assigns, so the two branches are the same
// branch. kenbi records what a branch proves about such a STABLE scalar — one it never assigns
// and never takes the address of — and a later test of it takes only the branch the path can
// still reach.
//
// THE LIMIT, stated plainly: the fact lives only as long as the path does. At the join after the
// first `if`, the two branches disagree about `want` and the fact is dropped, so the SEQUENTIAL
// form above is still reported. Only the nested form — where the second test is inside the first
// branch, with no join in between — is decided today. Deciding the sequential form needs the two
// paths to stay distinguished through the join (trace partitioning), which this is the
// groundwork for and not yet the whole of.

// @allocator t::heap { alloc: malloc, free: free }
int opt(void);
// @borrows(p)
void use(const char *p);

// --- 1. the nested form is decided ------------------------------------------------------------
// @kenbi
void nested_same_flag(void) {
  int want = opt();
  char *p = NULL;
  if (want) {
    p = (char *)malloc(16);
    if (want) free(p);      /* the same flag: the else path cannot happen here */
  }
}

// --- 2. the negated form too --------------------------------------------------------------------
// @kenbi
void nested_negated(void) {
  int skip = opt();
  char *p = NULL;
  if (!skip) {
    p = (char *)malloc(16);
    if (skip) use(p); else free(p);
  }
}

// --- 3. a parameter is stable too ----------------------------------------------------------------
// @kenbi
void stable_parameter(int want) {
  char *p = NULL;
  if (want) {
    p = (char *)malloc(16);
    if (want) free(p);
  }
}

// --- 4. a scalar the function ASSIGNS is not stable ------------------------------------------------
// Nothing may be concluded from the first test, so both branches of the second stay live.
// @kenbi
void reassigned_flag(void) {
  int want = opt();
  char *p = NULL;
  if (want) {
    p = (char *)malloc(16);   //EXPECT LEAK
    want = opt();
    if (want) free(p);
  }
}

// --- 5. two SEPARATE calls are not correlated -------------------------------------------------------
// `opt()` may answer differently each time, so this really can allocate without freeing.
// @kenbi
void two_calls(void) {
  char *p = NULL;
  if (opt()) {
    p = (char *)malloc(16);   //EXPECT LEAK
    if (opt()) free(p);
  }
}

// --- 6. a DIFFERENT stable flag is not the same flag --------------------------------------------------
// @kenbi
void different_flags(void) {
  int a = opt();
  int b = opt();
  char *p = NULL;
  if (a) {
    p = (char *)malloc(16);   //EXPECT LEAK
    if (b) free(p);
  }
}

// --- 7. the address-taken escape hatch ------------------------------------------------------------------
// `&want` hands the variable to something that can write it, so it is not stable.
// @kenbi
void address_taken(void) {
  int want = opt();
  char *p = NULL;
  int *alias = &want;
  use((const char *)alias);
  if (want) {
    p = (char *)malloc(16);   //EXPECT LEAK
    if (want) free(p);
  }
}

// --- 8. THE KNOWN LIMIT: the sequential form is still reported ------------------------------------------
// The join after the first `if` drops what the branches disagree about. Asserted so the day it
// is decided, this test says so.
// @kenbi
void sequential_form_not_yet(void) {
  int want = opt();
  char *p = NULL;
  if (want) p = (char *)malloc(16);   //EXPECT LEAK
  if (want) free(p);
}
