#include <stdlib.h>
// @kenbi
// @allocator test::heap { alloc: malloc, free: free }
// The configured-effect runner also checks this file through --safety. The
// legacy ownership runner must remain unchanged by the independent effect axis.
int external_wait(int ticks);
int external_unknown(int value);
int across_files(int value);

int pure(int value) { return value + 1; }
int helper(int value) { return pure(value); }
int allocates(void) {
  char *p = malloc(8);
  free(p);
  return 0;
}
int hidden_allocation(void) { return allocates(); }
int waits(void) { return external_wait(1); }
int irq_entry(void) { return waits(); }
int unknown_boundary(void) { return external_unknown(1); }
int indirect(int (*callback)(int)) { return callback(1); }
int recursive(int value) { return value ? recursive(value - 1) : 0; }
int cross_file_entry(void) { return across_files(1); }
int suppressed_allocation(void) {
  char *p = malloc(8); // @unsafe //EXPECT STALE_UNSAFE
  free(p);
  return 0;
}
