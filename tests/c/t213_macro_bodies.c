#include <stdlib.h>
// WHAT A CLEANUP MACRO DOES WAS INVISIBLE. C projects put their error-path cleanup in a macro —
// ImageMagick's `ThrowGaussJordanException()` / `CheckPathExtent()` are exactly this — and
// libclang collapses every cursor inside a macro expansion onto the invocation. kenbi recovers a
// binary operator from its tokens (libclang-14 has no accessor), and it did so by comparing the
// operands' source offsets, which in an expansion are identical for both operands and often
// inverted. So no operator was ever found inside a macro, and with it went:
//   * the ASSIGNMENT — a release written the house way (`p = Relinquish(p);`) was not lowered
//     at all, so the release was invisible and the memory it freed was reported leaked;
//   * the NULL GUARD around it, so the pointer stayed owned on the branch where it is NULL;
//   * `p = realloc(p, n)`, which never drew the OOM-overwrite finding it draws everywhere else.
// The operator is now the first punctuation at bracket depth zero of the token run, which is
// the top-level operator of any well-formed C expression — compound conditions included.

// @allocator t::m { alloc: Acquire, realloc: Resize, free_returns_null: Relinquish }
void *Acquire(int n);
void *Resize(void *p, int n);
void *Relinquish(void *p);
// @borrows(p)
void use(long *p);

#define CLEANUP() \
{ \
  if (pivots != (long *) NULL) \
    pivots=(long *) Relinquish(pivots); \
  if (rows != (long *) NULL) \
    rows=(long *) Relinquish(rows); \
  return 0; \
}

// the macro's releases are seen, and its null guards keep the pointer accounted for on the
// branch where it is NULL: nothing leaks here
static int cleanup_in_a_macro(int n) {
  long *pivots = (long *) Acquire(n);
  long *rows = (long *) Acquire(n);
  if ((pivots == (long *) NULL) || (rows == (long *) NULL))
    CLEANUP();
  use(pivots);
  use(rows);
  pivots = (long *) Relinquish(pivots);
  rows = (long *) Relinquish(rows);
  return 1;
}

// a realloc-into-itself inside a macro is the same OOM-overwrite it is anywhere else. The
// macro names the buffer directly, as a project's extend-this-path macros do; an operand that
// comes from a macro ARGUMENT is still beyond reach — its spelling is at the invocation while
// the operator's is in the definition, and no location relates the two.
static long *buf;
#define GROW(n) { buf=(long *) Resize(buf, n); }
static int grow_in_a_macro(int n) {
  buf = (long *) Acquire(n);
  GROW(2*n);   //EXPECT REALLOC_SELF_REASSIGN
  use(buf);
  buf = (long *) Relinquish(buf);
  return 1;
}

// A COMPOUND GUARD PROVES ITS OPERANDS NON-NULL ON THE OTHER BRANCH. C allocates several
// buffers and guards them together; without the fact, every later use of them was a
// possibly-null dereference (47 such claims in ImageMagick's draw.c alone).
static long together(int n) {
  long *a = (long *) Acquire(n);
  long *b = (long *) Acquire(n);
  if ((a == (long *) NULL) || (b == (long *) NULL))
    {
      if (a != (long *) NULL)
        a = (long *) Relinquish(a);
      if (b != (long *) NULL)
        b = (long *) Relinquish(b);
      return -1;
    }
  const long v = a[0] + b[0];   /* both are non-null here, and kenbi knows it */
  a = (long *) Relinquish(a);
  b = (long *) Relinquish(b);
  return v;
}

// ...and the `&&` form proves them on the THEN branch
static long both(int n) {
  long *a = (long *) Acquire(n);
  if ((a != (long *) NULL) && (a[0] > 0))
    use(a);
  a = (long *) Relinquish(a);
  return 0;
}
