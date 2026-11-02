#include <cstdlib>
#include <vector>
// A RANGE-FOR IS A LOOP. `for (T x : range) { ... }` used to be dropped whole — a `free` inside
// one was invisible, so a cross-iteration double free reported NOTHING (a false GREEN). It is
// modelled like a while loop (0+ iterations, bounded fixpoint), so in-body and cross-iteration
// hazards are caught, and the state after it is the join of the 0-trip and the body's exit.

// @borrows(s)
void use(char *s) noexcept;

// freeing inside the loop: the second iteration frees again — and on the 0-trip path (an empty
// range) nothing frees it at all, so both hazards are reported
static int free_in_range_for(const std::vector<int> &v) {
  /* @mem t::a { free: free, owner: p } */
  char *p = (char *)malloc(8);   //EXPECT LEAK
  for (int x : v) {
    free(p);   //EXPECT DOUBLE_FREE
    (void)x;
  }
  return 0;
}

// ... and the release after the loop is a further one
static int free_after_range_for(const std::vector<int> &v) {
  /* @mem t::b { free: free, owner: p } */
  char *p = (char *)malloc(8);
  for (int x : v) {
    (void)x;
    use(p);
  }
  free(p);
  return 0;
}

// the loop only reads; the single release after it is clean
static int read_in_range_for(const std::vector<int> &v) {
  /* @mem t::c { free: free, owner: p } */
  char *p = (char *)malloc(8);
  for (int x : v) {
    use(p);
    (void)x;
  }
  free(p);
  return 0;
}

// allocating inside the loop without releasing leaks on every iteration
static int alloc_in_range_for(const std::vector<int> &v) {
  for (int x : v) {
    /* @mem t::d { free: free, owner: q } */
    char *q = (char *)malloc(8);   //EXPECT LEAK
    use(q);
    (void)x;
  }
  return 0;
}
