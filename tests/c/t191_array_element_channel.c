#include <stdlib.h>
// AN ARRAY ELEMENT with a constant index is a field path: `arr[2] = data` stores the owner into
// the tracked element `arr[2]`, `free(arr[2])` releases it, and passing `arr` to a callee hands
// every tracked element across the boundary — `@borrows(arr)` a read, `@frees(arr[2])` a
// transfer of that element, no contract the usual UNCONTRACTED_ESCAPE (the Juliet 66 channel).

void unknown_sink(char *arr[]);
// @borrows(arr)
void read_sink(char *arr[]);
// @frees(arr[2])
void free_sink(char *arr[]);

// no contract: the element crosses an undeclared boundary
static void escape_uncontracted(void) {
  char *arr[5];
  /* @mem t::a { free: free, owner: data } */
  char *data = malloc(8);
  arr[2] = data;
  unknown_sink(arr);   //EXPECT UNCONTRACTED_ESCAPE
}

// a declared reader: the element is still owned here and never released
static void leak_past_reader(void) {
  char *arr[5];
  /* @mem t::b { free: free, owner: data } */
  char *data = malloc(8);   //EXPECT LEAK
  arr[2] = data;
  read_sink(arr);
}

// ... released after the reader -> clean
static void ok_after_reader(void) {
  char *arr[5];
  /* @mem t::c { free: free, owner: data } */
  char *data = malloc(8);
  arr[2] = data;
  read_sink(arr);
  free(arr[2]);
}

// a declared freeing sink transfers the element: releasing it again is a double free
static void double_after_freer(void) {
  char *arr[5];
  /* @mem t::d { free: free, owner: data } */
  char *data = malloc(8);
  arr[2] = data;
  free_sink(arr);
  free(arr[2]);   //EXPECT DOUBLE_FREE
}
