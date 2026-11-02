#include <stdlib.h>
// `free(NULL)` IS DEFINED TO DO NOTHING, so the standard defensive idiom — release, then set
// the pointer to NULL — must not read as a double free at the next release. Two shapes: the
// plain `p = NULL`, and the house style where the release itself hands back NULL and is
// assigned over the pointer (`p = release(p)`), declared with `free_returns_null`.

// @allocator proj::mem { alloc: mem_alloc, free_returns_null: mem_free }
void *mem_alloc(int n);
void *mem_free(void *p);
// @borrows(s)
void use(char *s);

// release, null out, release again on another path: legal
static void null_then_free_again(int c) {
  /* @mem demo::a { free: free, owner: p } */
  char *p = malloc(8);
  free(p);
  p = NULL;
  if (c) free(p);
}

// the assign-back idiom, twice
static void release_returns_null(int c) {
  char *p = mem_alloc(8);
  p = (char *) mem_free(p);
  if (c) p = (char *) mem_free(p);
}

// nulling it out does NOT excuse the earlier double release
static void real_double_free(void) {
  /* @mem demo::b { free: free, owner: p } */
  char *p = malloc(8);
  free(p);
  free(p);   //EXPECT DOUBLE_FREE
  p = NULL;
}

// ... nor does it discharge an obligation: nulling the only handle loses the block
static void null_without_free(void) {
  /* @mem demo::c { free: free, owner: p } */
  char *p = malloc(8);   //EXPECT LEAK
  use(p);
  p = NULL;
}

// a fresh allocation after the null rebinds it: the release below is a real one
static void realloc_after_null(void) {
  /* @mem demo::d { free: free, owner: p } */
  char *p = malloc(8);
  free(p);
  p = NULL;
  /* @mem demo::e { free: free, owner: p } */
  p = malloc(8);
  free(p);
  free(p);   //EXPECT DOUBLE_FREE
}

// the null is PER PATH: one branch nulling the pointer must not silence the release on
// another (this silenced every later release and turned correct code into a LEAK)
static void null_on_one_branch(int c) {
  /* @mem demo::f { free: free, owner: p } */
  char *p = malloc(8);
  if (c) {
    free(p);
    p = NULL;
    return;
  }
  use(p);
  free(p);
}

// ... and a release after a branch that nulled it is CORRECT C: on that branch the pointer is
// null and the release does nothing, on the other it is the only release
static void null_branch_then_free(int c) {
  /* @mem demo::g { free: free, owner: p } */
  char *p = malloc(8);
  if (c) {
    free(p);
    p = NULL;
  }
  free(p);
}
