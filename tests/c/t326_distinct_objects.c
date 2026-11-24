#include <stdlib.h>
// DIFFERENT OBJECTS, DECLARED. `@distinct(a, b)` above a function declares that the parameters
// and globals it names are different objects for the length of a call — what the function
// relies on when it keeps a pointer into one while another is changed. Each call is checked:
// the same object passed for two of them is DISTINCT_ALIASED, a pair nothing shows to be
// different is DISTINCT_UNPROVEN. Shown different: distinct variables, distinct members of one
// struct, separate allocations made in the caller, a local nothing else has the address of,
// and what the caller itself declares `@distinct`. A global stands for the object it is or
// points to, so only a local whose address is taken nowhere else, or a parameter the caller
// declares distinct from that global, is shown different from it.

struct Buf { char *data; unsigned len, cap; };
struct Pair { struct Buf first; struct Buf second; };
static struct Buf *current;

// @distinct(a, b)
void merge(struct Buf *a, struct Buf *b);
// @distinct(b, current)
void mark_first(struct Buf *b);

// the same object for both
// @kenbi
void same_object(struct Buf *p) {
  merge(p, p);                                    //EXPECT DISTINCT_ALIASED
}

// two parameters nothing is declared about
// @kenbi
void two_parameters(struct Buf *p, struct Buf *q) {
  merge(p, q);                                    //EXPECT DISTINCT_UNPROVEN
}

// a parameter beside the object a global points to
// @kenbi
void parameter_and_global(struct Buf *p) {
  mark_first(p);                                  //EXPECT DISTINCT_UNPROVEN
}

// the global itself
// @kenbi
void the_global(void) {
  mark_first(current);                            //EXPECT DISTINCT_ALIASED
}

// a local whose address the global was given
// @kenbi
void local_made_global(void) {
  struct Buf buf = {0};
  current = &buf;
  mark_first(&buf);                               //EXPECT DISTINCT_UNPROVEN
  current = 0;
}

// two locals, and two members of one struct
// @kenbi
void locals_and_members(struct Pair *pair) {
  struct Buf x = {0};
  struct Buf y = {0};
  merge(&x, &y);
  merge(&pair->first, &pair->second);
}

// the caller declares the same of its own parameters
// @kenbi
// @distinct(p, q)
void caller_declares(struct Buf *p, struct Buf *q) {
  merge(p, q);
}

// ... and of its parameter and the global
// @kenbi
// @distinct(p, current)
void caller_declares_global(struct Buf *p) {
  mark_first(p);
}

// a local nothing else has the address of is not what the global points to
// @kenbi
void private_local(void) {
  struct Buf buf = {0};
  mark_first(&buf);
}
