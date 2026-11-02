#include <stdlib.h>
// TWO VERDICTS KENBI COULD NOT BACK, ON CODE WITH NOTHING WRONG WITH IT. Both came from a join
// losing a fact that belonged to one path.

// @allocator t::m { alloc: Acquire, free_returns_null: Relinquish }
void *Acquire(int n);
void *Relinquish(void *p);
// @borrows(p)
void use(double *p);
// @borrows(p)
void useq(int *p);

// (1) AN APPROXIMATION REPORTED AS A FACT. A variable that may name either of two allocations
// makes kenbi merge them — one origin, so a release through the variable discharges "whatever it
// is" and neither allocation becomes a phantom leak. That merge is invisible only while nothing
// else tells the two apart. Here `x_vector` names the first buffer throughout, so freeing each
// buffer exactly once read as a double free OF THE MERGE. The merge is kenbi's, not the
// program's, so a second release through it is now a POSSIBLE_DOUBLE_FREE — still RED, still
// asking for one handle per allocation, but no longer an accusation. (ImageMagick resize.c ×2.)
static void two_buffers_one_handle(int rows, int scale_rows, int n) {
  /* @mem t::v { free: free, owner: x_vector } */
  double *x_vector = (double *) malloc(n * sizeof(double));
  double *scanline = x_vector;
  if (rows != scale_rows) {
    /* @mem t::s { free: free, owner: scanline } */
    scanline = (double *) malloc(n * sizeof(double));
  }
  use(scanline);
  use(x_vector);
  if ((rows != scale_rows) && (scanline != NULL))
    free(scanline);
  free(x_vector);   //EXPECT POSSIBLE_DOUBLE_FREE
}

// ...and a handle that really does name ONE object per path keeps its verdict: nothing else
// distinguishes these two allocations, so freeing twice is a double free and is reported as one
static void one_object_per_path(int c) {
  char *p;
  if (c) {
    /* @mem t::a { free: free, owner: p } */
    p = (char *) malloc(8);
  } else {
    /* @mem t::b { free: free, owner: p } */
    p = (char *) malloc(16);
  }
  free(p);
  free(p);   //EXPECT DOUBLE_FREE
}

// (2) A `break` CARRIES ITS OWN LIVENESS. The case that releases the buffer also nulls the
// handle (`p = Relinquish(p)`, the house style), so at that case's exit no handle names the
// origin and its freed state reaches nothing. The fall-through exit already dropped such an
// orphan; the break edges were merged raw, so the release after the switch — reached only from
// the cases that did NOT free — read as a double free. (ImageMagick stream.c.)
static void released_in_one_case(int kind, int n) {
  int *quantum_map = (int *) Acquire(n);
  switch (kind) {
    case 0:
      useq(quantum_map);
      break;
    default:
      quantum_map = (int *) Relinquish(quantum_map);
      break;
  }
  quantum_map = (int *) Relinquish(quantum_map);
}

// ...and a case that releases WITHOUT nulling still hands the freed state on: the handle still
// names the origin there, so the release after the switch is the double free it is
static void released_without_nulling(int kind, int n) {
  /* @mem t::q { free: free, owner: map } */
  int *map = (int *) malloc(n * sizeof(int));
  switch (kind) {
    case 0:
      useq(map);
      break;
    default:
      free(map);
      break;
  }
  free(map);   //EXPECT DOUBLE_FREE
}
