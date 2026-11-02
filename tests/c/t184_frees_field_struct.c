#include <stdlib.h>
// `@frees(p.f)` names a struct FIELD of a by-value parameter: the callee frees `myStruct.structFirst`.
// A struct-var argument therefore transfers ownership of `arg.structFirst` across the boundary —
// modular detection of the cross-file struct source/sink form (Juliet _67/_68), reusing the #2 field
// ownership that `myStruct.structFirst = data` sets up. No whole-program pass.
typedef struct { char *structFirst; } S;
// @frees(myStruct.structFirst)
void sink(S myStruct);   // definition in another file; frees myStruct.structFirst

// @kenbi
void double_free(void) {
  char *data;
  S myStruct;
  /* @mem j::b { free: free, owner: data } */
  data = (char *)malloc(100);
  free(data);
  myStruct.structFirst = data;
  sink(myStruct);   // sink frees the field (data), already freed here -> double free   //EXPECT DOUBLE_FREE
}

// @kenbi
void transfer_ok(void) {
  char *data;
  S myStruct;
  /* @mem j::b { free: free, owner: data } */
  data = (char *)malloc(100);
  myStruct.structFirst = data;
  sink(myStruct);   // ownership handed to the sink through the field (frees once) -> clean
}
