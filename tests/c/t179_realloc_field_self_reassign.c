// @kenbi
#include <stdlib.h>
// RED: the field-path twin of t177. `b->data = realloc(b->data, n)` self-reassigns a tracked
// field: on OOM the NULL result overwrites the only handle to the original field block, which
// then leaks. The safe idiom (temporary + reconcile, as in t167's realloc_field_ok) stays green.
struct box { char *data; };
void f(struct box *b, int n) {
  /* @mem g::buf { free: free, owner: data } */
  b->data = (char *)malloc(16);
  b->data = (char *)realloc(b->data, n);   // field self-realloc: original leaks if realloc fails   //EXPECT REALLOC_SELF_REASSIGN
  free(b->data);
}
