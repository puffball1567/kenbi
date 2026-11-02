#include <stdlib.h>
// A NULL GUARD MEANS THE SAME THING ON A FIELD AS ON A VARIABLE.
//
// The guard recogniser accepted a plain variable only, so the two halves of the same idiom
// disagreed:
//
//     if (p == NULL)       p       = malloc(n);   /* clean */
//     if (b->blob == NULL) b->blob = malloc(n);   /* a false overwrite-leak */
//
// The second is ImageMagick's `AcquireVirtualMemory` (memory.c:738), which tries an aligned
// allocation, then a memory map, then a plain one — each fall-back guarded by the field still
// being NULL, so nothing is ever overwritten while it owns anything. A one-level field path is
// tracked under the same kind of key as a variable, so once the recogniser sees it, every
// narrowing downstream works unchanged.

// @allocator t::heap { alloc: malloc, free: free }
struct box { char *blob; char *other; };
int cond(void);
// @borrows(p)
void use(const char *p);

// --- 1. the fall-back chain: each overwrite is guarded by the field being NULL --------------
// @kenbi
// @borrows(b)
void fallback_chain(struct box *b) {
  b->blob = NULL;
  if (cond()) b->blob = (char *)malloc(16);
  if (b->blob == NULL)
    b->blob = (char *)malloc(32);
  if (b->blob == NULL)
    return;
  free(b->blob);
}

// --- 2. the plain-variable twin, which always worked ------------------------------------------
// @kenbi
void plain_variable_twin(void) {
  char *p = NULL;
  if (cond()) p = (char *)malloc(16);
  if (p == NULL)
    p = (char *)malloc(32);
  if (p == NULL)
    return;
  free(p);
}

// --- 3. the truth form (`if (b->blob)`) narrows too -------------------------------------------
// @kenbi
// @borrows(b)
void truth_form(struct box *b) {
  b->blob = NULL;
  if (cond()) b->blob = (char *)malloc(16);
  if (!b->blob)
    b->blob = (char *)malloc(32);
  if (b->blob)
    free(b->blob);
}

// --- 4. an UNGUARDED overwrite of a field that still owns is still a leak ----------------------
// @kenbi
// @borrows(b)
void unguarded_overwrite(struct box *b) {
  b->blob = (char *)malloc(16);   //EXPECT LEAK
  b->blob = (char *)malloc(32);
  free(b->blob);
}

// --- 5. …and a guard on a DIFFERENT field does not narrow this one -----------------------------
// @kenbi
// @borrows(b)
void guard_on_another_field(struct box *b) {
  b->blob = (char *)malloc(16);   //EXPECT LEAK
  if (b->other == NULL)
    b->blob = (char *)malloc(32);
  free(b->blob);
}

// --- 6. a compound guard proves the field non-null on the fall-through -------------------------
// @kenbi
// @borrows(b)
void compound_guard(struct box *b, int n) {
  b->blob = (char *)malloc(n);
  if ((n <= 0) || (b->blob == NULL))
    return;
  use(b->blob);
  free(b->blob);
}
