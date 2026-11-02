#include <stdlib.h>
// A CALL THROUGH A FUNCTION POINTER resolves its ownership contracts through the pointer's
// declared `@calls(f, g, ...)` targets — the effect every target agrees on. An undeclared
// pointer, or targets that disagree, give no contract: the argument crosses an uncontracted
// boundary (default-red), never the most convenient target's contract.

// @frees(p)
static void take(char *p) { free(p); }
// @borrows(p)
static void look(char *p) { (void)p; }

// the declared target frees: a second free is a double free
static void via_declared_freer(void) {
  /* @mem t::a { free: free, owner: data } */
  char *data = malloc(8);
  // @calls(take)
  void (*fp)(char *) = take;
  fp(data);
  free(data);   //EXPECT DOUBLE_FREE
}

// the declared target only reads: the owner is never released
static void via_declared_reader_leaks(void) {
  /* @mem t::b { free: free, owner: data } */
  char *data = malloc(8);   //EXPECT LEAK
  // @calls(look)
  void (*fp)(char *) = look;
  fp(data);
}

// no declared targets: the boundary is uncontracted
static void undeclared_targets(void) {
  /* @mem t::c { free: free, owner: data } */
  char *data = malloc(8);
  void (*fp)(char *) = look;
  fp(data);   //EXPECT UNCONTRACTED_ESCAPE
  free(data);
}

// declared targets that disagree (one frees, one reads): no contract can be assumed
static void disagreeing_targets(void) {
  /* @mem t::d { free: free, owner: data } */
  char *data = malloc(8);
  // @calls(take, look)
  void (*fp)(char *) = look;
  fp(data);   //EXPECT UNCONTRACTED_ESCAPE
  free(data);
}
