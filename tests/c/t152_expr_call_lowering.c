// Regression: a call's ARGUMENT effects (@moves / @frees / borrow / uncontracted escape)
// must be lowered in EVERY expression position, not only statement form. A call whose
// result is assigned, returned, or sits under an operator or in a condition otherwise
// never reached lowerCall, so an owned pointer passed to it was left owned and FALSE-LEAKed
// at the function exit. Pilot: quickjs-ng js_worker_ctor (`ret = js_thread_create(..,args,..)`).
#include <stdlib.h>

// @moves(p)
int take(char *p);      // consumes p (thread/queue handoff)
int unknown(char *p);   // uncontracted: what it does with p is undecidable

int rhs_move(int n) {
  /* @mem r1 { free: free, owner: p } */
  char *p = malloc(n);
  if (!p) return -1;
  int r = take(p);        // assignment-RHS call: @moves(p) applied -> p moved, NOT a leak
  return r;
}

int return_move(int n) {
  /* @mem r2 { free: free, owner: p } */
  char *p = malloc(n);
  if (!p) return -1;
  return take(p);         // return-expression call: @moves(p) applied -> NOT a leak
}

int nested_move(int n) {
  /* @mem r3 { free: free, owner: p } */
  char *p = malloc(n);
  if (!p) return -1;
  int r = take(p) + 1;    // call UNDER an operator: args still lowered -> NOT a leak
  return r;
}

int rhs_escape(int n) {
  /* @mem r4 { free: free, owner: p } */
  char *p = malloc(n);
  if (!p) return -1;
  int r = unknown(p);   //EXPECT UNCONTRACTED_ESCAPE
  return r;             // honest verdict at the boundary — NOT a bare LEAK
}

int cond_escape(int n) {
  /* @mem r5 { free: free, owner: p } */
  char *p = malloc(n);
  if (!p) return -1;
  if (unknown(p) != 0)  //EXPECT UNCONTRACTED_ESCAPE
    return 1;
  return 0;
}
