//ARGS -DDEMO_ABI=3
#include <stdlib.h>
// CONTRACTS SHIPPED FOR A LIBRARY DESCRIBE A PARTICULAR BUILD OF IT. An overlay can now say
// whose contracts it carries, which version they were written for, and which build conditions
// they assume — and the assumptions are CHECKED, because "these contracts apply here" is a
// claim like any other:
//
//   * `requires: NAME=VALUE` is checked against the compile line. A build that CONTRADICTS one
//     is an error: the contracts were written for a different build, so what they promise may
//     not hold. A condition the compile line does not settle is an advisory — reported as
//     unverified, never as satisfied.
//   * `version:` is carried as DECLARED. kenbi cannot read a library's version out of source,
//     and says so rather than implying it checked.
//
// This file is compiled with `-DDEMO_ABI=3` while the package declares 2 (see //ARGS above).

// @contracts_for demolib { version: 2.4.1, requires: DEMO_ABI=2 }
// @allocator demo::mem { alloc: demo_alloc, free: demo_free }
//EXPECT CONTRACT_PACKAGE_MISMATCH@0

void *demo_alloc(int n);
void demo_free(void *p);
// @borrows(p)
void use(char *p);

// the contracts still apply — the mismatch is reported, not silently ignored, and the
// finding it produces is the one the contracts describe
// @kenbi
static void leaks(void) {
  char *p = (char *) demo_alloc(8);   //EXPECT LEAK
  use(p);
}
