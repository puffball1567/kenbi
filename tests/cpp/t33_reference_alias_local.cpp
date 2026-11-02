#include <cstdlib>
// A C++ REFERENCE bound to a local (`char *&dataRef = data;`) IS that local for its whole
// lifetime (it cannot be reseated): every use of the reference resolves to `data` — allocating
// through it allocates `data`, copying it copies `data`, freeing it frees `data` (Juliet 33).

// @borrows(s)
void use(char *s) noexcept;

// allocated through the reference, read back through it in a shadowing block, never freed
static void via_reference_leaks() {
  char *data;
  char *&dataRef = data;
  data = nullptr;
  /* @mem t::a { free: free, owner: data } */
  data = (char *)malloc(8);   //EXPECT LEAK
  {
    char *data = dataRef;
    use(data);
  }
}

// ... freed through the shadowing copy -> clean
static void via_reference_freed() {
  char *data;
  char *&dataRef = data;
  /* @mem t::b { free: free, owner: data } */
  data = (char *)malloc(8);
  {
    char *data = dataRef;
    free(data);
  }
}

// allocated THROUGH the reference, freed twice through both names
static void alloc_via_reference_double_free() {
  char *data;
  char *&dataRef = data;
  /* @mem t::c { free: free, owner: dataRef } */
  dataRef = (char *)malloc(8);
  free(dataRef);
  free(data);   //EXPECT DOUBLE_FREE
}
