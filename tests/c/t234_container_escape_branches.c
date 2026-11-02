#include <stdlib.h>
// A returned container transfers its fields on THAT path only.
// @allocator t::heap { alloc: malloc, free: free }
struct box { char *data; };

// @kenbi
struct box return_then_only(int take) {
  struct box b, empty = {0};
  b.data = malloc(8); //EXPECT LEAK
  if (take) return b;
  return empty;
}

// @kenbi
struct box return_else_only(int take) {
  struct box b, empty = {0};
  b.data = malloc(8); //EXPECT LEAK
  if (take) { } else return b;
  return empty;
}

// @kenbi
struct box return_both(int take) {
  struct box b;
  b.data = malloc(8);
  if (take) return b; else return b;
}

// @kenbi
struct box return_or_release(int take) {
  struct box b, empty = {0};
  b.data = malloc(8);
  if (take) return b;
  free(b.data);
  return empty;
}
