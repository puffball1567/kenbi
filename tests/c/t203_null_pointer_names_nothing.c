#include <stdlib.h>
// A POINTER SET TO NULL NAMES NOTHING. After `p = NULL` it no longer refers to whatever it
// held, so using it, copying it or deriving from it is not a reference to an unknown variable
// — the parser idiom `obj = Acquire(); ... ; hand_over(obj); obj = NULL;` in a loop hit this on
// every later mention of `obj`.

// @borrows(s)
void use(char *s);
// @frees(p)
void hand_over(char *p);

static void null_then_mentioned(int c) {
  /* @mem d::a { free: free, owner: p } */
  char *p = malloc(8);
  hand_over(p);
  p = NULL;
  if (c)
    use(p);          /* using a null pointer: not an unknown variable */
  char *q = p;       /* copying it: q is null too */
  use(q);
  char *r = p + 1;   /* deriving from it */
  use(r);
}

// ... and a real use of a live pointer is still tracked through the same shapes
static void still_tracked(void) {
  /* @mem d::b { free: free, owner: p } */
  char *p = malloc(8);
  char *q = p;
  free(q);
  use(p);   //EXPECT USE_AFTER_FREE
}
