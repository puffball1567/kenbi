#include <stdlib.h>
// A POINTER TO A LOCAL (`dataPtr = &data`) is a second name for that local: a store through it
// (`*dataPtr = x`) assigns `data`, a read (`y = *dataPtr`) copies it, and passing `*dataPtr`
// passes `data` — so the obligation follows the local instead of vanishing into an untracked
// store (the Juliet 32 shape: a shadowed inner `data` written back through the pointer).

// @borrows(s)
void use(char *s);

// the inner block allocates and writes the owner back through the pointer; nobody frees it
static void write_back_leaks(void) {
  char *data;
  char **dataPtr = &data;
  data = NULL;
  {
    char *data = *dataPtr;
    /* @mem t::a { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
    *dataPtr = data;
  }
  {
    char *data = *dataPtr;
    use(data);
  }
}

// ... the second block frees what it reads through the pointer -> clean
static void write_back_freed(void) {
  char *data;
  char **dataPtr = &data;
  data = NULL;
  {
    char *data = *dataPtr;
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);
    *dataPtr = data;
  }
  {
    char *data = *dataPtr;
    free(data);
  }
}

// freeing through the pointer and then through the local is a double free
static void free_through_both(void) {
  char *data;
  char **dataPtr = &data;
  /* @mem t::c { free: free, owner: data } */
  data = malloc(8);
  free(*dataPtr);
  free(data);   //EXPECT DOUBLE_FREE
}
