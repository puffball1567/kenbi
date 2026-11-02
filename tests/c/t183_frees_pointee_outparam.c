#include <stdlib.h>
// `@frees(*p)` names the POINTEE of an out-parameter: the callee frees `*dataPtr`. A `&data`
// argument therefore transfers ownership of `data` itself across the boundary — modular detection
// of the cross-file `T**` source/sink form (Juliet _63/_64/_68), no whole-program pass needed.
// @frees(*dataPtr)
void sink(char **dataPtr);   // definition lives in another file; frees *dataPtr

// @kenbi
void double_free(void) {
  /* @mem j::b { free: free, owner: data } */
  char *data = (char *)malloc(100);
  free(data);
  sink(&data);   // sink frees the pointee (data), already freed here -> double free   //EXPECT DOUBLE_FREE
}

// @kenbi
void transfer_ok(void) {
  /* @mem j::b { free: free, owner: data } */
  char *data = (char *)malloc(100);
  sink(&data);   // ownership handed to the sink (frees exactly once) -> clean, no leak
}

// @kenbi
void use_after_transfer(void) {
  /* @mem j::b { free: free, owner: data } */
  char *data = (char *)malloc(100);
  sink(&data);   // transferred (freed by sink)
  free(data);    // freeing after the sink already released it -> double free   //EXPECT DOUBLE_FREE
}
