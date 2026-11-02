// @initcheck
// INIT (definite-assignment) GATING. A local read before it is DEFINITELY ASSIGNED on every
// path is USE_OF_UNINITIALIZED — an indeterminate value (a wild pointer / garbage int). A
// MUST-analysis: the assigned-set is the INTERSECTION across branches (assigned only if assigned
// on every path). `&v` (a callee may initialise it), both-branch assignment, and an exhaustive
// `switch` (with `default:`) are recognised as assigned — low false-positive. Opt-in via
// `@initcheck`, so existing files are never init-checked. Default-red.
extern void use(int x);
extern void sink(int *p);

// (1) GREEN: initialised at its declaration.
int init_at_decl(void) {
  int v = 5;
  return v;                            // assigned — ok
}

// (2) GREEN: assigned, then read.
int assign_then_read(void) {
  int v;
  v = 7;
  return v;                            // assigned — ok
}

// (3) GREEN: assigned on BOTH branches.
int both_branches(int c) {
  int v;
  if (c) { v = 1; } else { v = 2; }
  return v;                            // assigned on every path — ok
}

// (4) GREEN: address taken before the read (a callee may initialise it).
int addr_taken(void) {
  int v;
  sink(&v);
  return v;                            // &v assumed to assign — ok
}

// (5) GREEN: an exhaustive switch (a `default:` assigns on the no-match path).
int switch_default(int c) {
  int v;
  switch (c) {
    case 1:  v = 1; break;
    default: v = 0; break;
  }
  return v;                            // every path assigns — ok
}

// (6) RED: read with no assignment.
int read_uninit(void) {
  int v;
  return v;                            //EXPECT USE_OF_UNINITIALIZED
}

// (7) RED: assigned on only ONE branch.
int one_branch(int c) {
  int v;
  if (c) { v = 1; }
  return v;                            //EXPECT USE_OF_UNINITIALIZED
}

// (8) RED: a switch with NO default — a no-match path leaves v unassigned.
int switch_no_default(int c) {
  int v;
  switch (c) {
    case 1: v = 1; break;
    case 2: v = 2; break;
  }
  return v;                            //EXPECT USE_OF_UNINITIALIZED
}
