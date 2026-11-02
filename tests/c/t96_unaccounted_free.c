#include <stdlib.h>
// Generalised intake-side default-red: freeing a pointer whose ownership kenbi cannot
// account for — an untracked local (assigned from `*outparam` or a non-@owns factory),
// or a direct deref — is UNCONTRACTED_RELEASE in covered scope. This closes the "free
// kenbi can't see" soundness hole: an unseen free could not be caught as a double-free
// even once the code is correctly annotated.

char *make(void);

// (1) a local assigned from an out-parameter deref, then freed
void via_outparam(char **pp) {
  char *data = *pp;
  free(data);              //EXPECT UNCONTRACTED_RELEASE
}

// (2) a direct deref free `free(*pp)`
void direct_deref(char **pp) {
  free(*pp);               //EXPECT UNCONTRACTED_RELEASE
}

// (3) a local from a factory return with no @owns contract
void from_factory(void) {
  char *data = make();
  free(data);              //EXPECT UNCONTRACTED_RELEASE
}

// (4) freeing NULL is not a release of a pointer kenbi lost track of -> clean
void free_null(void) {
  free(NULL);
}
