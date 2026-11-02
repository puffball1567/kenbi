// @kenbi
// An entry point that calls nothing but has a finding of its own: its flow has no blockers, and
// must still not be verified. Static-analysis input for tests/run_tests_project.nim.
#include <stdlib.h>

/* @mem red::buf { alloc: malloc, free: free } */

char *red_entry(int c) {
  char *p = malloc(8);
  if (!p) return NULL;
  if (c) return NULL;
  return p;
}
