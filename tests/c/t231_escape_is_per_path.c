#include <stdlib.h>
// AN ESCAPE ON ONE PATH IS NOT AN ESCAPE ON THE OTHER — AND THE STATE HAS TO SAY SO.
//
// When an obligation leaves kenbi's view (stored into a location it cannot follow, or handed to
// an uncontracted callee) the origin is marked `asEscaped` so the exit scan does not ALSO call
// it a leak: the escape is the finding, and the caller resolves it.
//
// That flag used to be ADDED to a still-owned state, which made `{asOwned, asEscaped}` mean two
// different things — "escaped on this path" and "escaped on one incoming path, still held on
// another" — and the leak scan, which read the flag as a suppressor, could not tell them apart:
//
//     if (cond()) *out = p;   /* escapes here */
//     /* the fall-through drops p — and was SILENT, a false GREEN */
//
// An escape now CLEARS `asOwned` on its own path. A join with a path that still holds the
// resource carries `asOwned` again, and the leak scan needs no special case: `asOwned` means
// some reaching path still owes the release.

// @allocator t::heap { alloc: malloc, free: free }
int cond(void);
void opaque(char *p);            /* no contract: a genuine uncontracted escape */
// @borrows(p)
void reader(const char *p);

// --- 1. a store through `*out` on one path only ------------------------------------------------
// @kenbi
// @borrows(out)
void store_deref(char **out) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  if (cond()) *out = p;   //EXPECT ESCAPE_UNCHECKED
}

// --- 2. an uncontracted CALL escape on one path only -------------------------------------------
// @kenbi
void call_escape(void) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  if (cond()) opaque(p);   //EXPECT UNCONTRACTED_ESCAPE
}

// --- 3. an array store on one path only ---------------------------------------------------------
// @kenbi
// @borrows(arr)
void store_index(char **arr, int i) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  if (cond()) arr[i] = p;   //EXPECT ESCAPE_UNCHECKED
}

// --- 4. an escape on EVERY path is still not a leak ---------------------------------------------
// The escape is the finding and the caller resolves it; reporting a leak on top of it would be
// the same obligation counted twice.
// @kenbi
// @borrows(out)
void escapes_on_both_paths(char **out) {
  char *p = (char *)malloc(16);
  if (p == NULL) return;
  if (cond())
    *out = p;   //EXPECT ESCAPE_UNCHECKED
  else
    *out = p;   //EXPECT ESCAPE_UNCHECKED
}

// --- 5. …and an escape followed by an unconditional release is still not a leak ------------------
// @kenbi
void escape_then_release(void) {
  char *p = (char *)malloc(16);
  if (p == NULL) return;
  if (cond()) opaque(p);   //EXPECT UNCONTRACTED_ESCAPE
  else free(p);
}

// --- 6. a declared `@escapes` store leaves nothing behind on that path ---------------------------
// The declaration removes the ESCAPE_UNCHECKED; the leak on the path that did NOT store is
// exactly as real as before, which is what makes the declaration a claim and not a silencer.
// @kenbi
// @borrows(out)
void declared_escape_one_path(char **out) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  if (cond()) *out = p;   // @escapes
}

// --- 7. a plain read is not an escape ------------------------------------------------------------
// @kenbi
void borrowed_read(void) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  if (cond()) reader(p);
}
