#include <stdlib.h>
// A STRUCT PASSED BY VALUE carries its owned field across the call (the Juliet 66/67 channel).
// `sink(s)` with no contract on `s` is an UNCONTRACTED_ESCAPE of every tracked field (the callee
// may take it — default-red, never silent); `@borrows(s)` makes it a read (the field stays
// owned here: a leak if never released); `@frees(s.f)` transfers the field.

typedef struct { char *buf; int n; } Pack;

void unknown_sink(Pack p);
// @borrows(p)
void read_sink(Pack p);
// @frees(p.buf)
void free_sink(Pack p);

// no contract: the field crosses an undeclared boundary
static void escape_uncontracted(void) {
  Pack s;
  /* @mem t::a { free: free, owner: data } */
  char *data = malloc(8);
  s.buf = data;
  unknown_sink(s);   //EXPECT UNCONTRACTED_ESCAPE
}

// a declared reader: the field is still owned here and never released
static void leak_past_reader(void) {
  Pack s;
  /* @mem t::b { free: free, owner: data } */
  char *data = malloc(8);   //EXPECT LEAK
  s.buf = data;
  read_sink(s);
}

// ... released after the reader -> clean
static void ok_after_reader(void) {
  Pack s;
  /* @mem t::c { free: free, owner: data } */
  char *data = malloc(8);
  s.buf = data;
  read_sink(s);
  free(s.buf);
}

// a declared freeing sink transfers the field: releasing it again is a double free
static void double_after_freer(void) {
  Pack s;
  /* @mem t::d { free: free, owner: data } */
  char *data = malloc(8);
  s.buf = data;
  free_sink(s);
  free(s.buf);   //EXPECT DOUBLE_FREE
}
