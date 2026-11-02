#include <stdlib.h>
// A CONSTANT LOOP GUARD MEANS THE BODY ALWAYS RUNS.
//
// `while (1) { … break; }` and `for (;;) { … break; }` are the ordinary way C writes a block
// that runs once and can bail out early, and a `do … while` body runs before its test. None of
// them has a cond-false exit at the head, so the never-ran 0-trip state is not one of their
// exits — and treating it as one says the allocation inside may be skipped and the release
// inside may never run, a leak the program cannot produce.
//
// The fold is a compile-time one (an absent condition, a literal, a TU-private `static const`),
// so a loop whose guard is a real runtime test keeps both exits and stays default-red.

// @allocator t::heap { alloc: malloc, free: free }
int maybe(void);

static const int kAlways = 1;

// --- 1. `while (1) { alloc; break; }` then `while (1) { free; break; }` ----------------------
// @kenbi
void forever_while(void) {
  char *data = NULL;
  while (1) {
    data = (char *)malloc(100);
    if (data == NULL) return;
    break;
  }
  while (1) {
    free(data);
    break;
  }
}

// --- 2. `for (;;)` — no condition clause at all ----------------------------------------------
// @kenbi
void forever_for(void) {
  char *p = NULL;
  for (;;) {
    p = (char *)malloc(16);
    if (p == NULL) return;
    break;
  }
  for (;;) {
    free(p);
    break;
  }
}

// --- 3. a folded constant: a file-scope `static const` this TU never writes -------------------
// @kenbi
void forever_named(void) {
  char *p = NULL;
  while (kAlways) {
    p = (char *)malloc(16);
    if (p == NULL) return;
    break;
  }
  while (kAlways) {
    free(p);
    break;
  }
}

// --- 4. a do-while body always runs, so the release inside it always runs ---------------------
// @kenbi
void do_while_releases(void) {
  char *p = (char *)malloc(16);
  if (p == NULL) return;
  do {
    free(p);
  } while (0);
}

// --- 5. a REAL runtime condition keeps the 0-trip exit: the release may be skipped ------------
// @kenbi
void runtime_guard(void) {
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (p == NULL) return;
  while (maybe()) {
    free(p);
    break;
  }
}

// --- 6. the constant-guard loop still sees what happens INSIDE it -----------------------------
// @kenbi
void forever_double_free(void) {
  char *p = (char *)malloc(16);
  if (p == NULL) return;
  for (;;) {
    free(p);
    free(p);   //EXPECT DOUBLE_FREE
    break;
  }
}

// --- 7. every exit edge is joined, not overwritten by the last one analysed -------------------
// A handle advanced off the start of its block on ONE break path is still interior after the
// loop.
// @kenbi
void forever_interior_on_break(void) {
  char *p = (char *)malloc(64);   //EXPECT LEAK
  if (p == NULL) return;
  while (1) {
    if (maybe()) {
      p += 8;
      break;
    }
    break;
  }
  free(p);   //EXPECT FREE_INTERIOR
}
