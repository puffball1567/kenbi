// @spatial
// REGRESSION: an opt-in coverage marker (@spatial / @kenbi / @threadsafe / @initcheck /
// @typecheck) must NOT bind to a bare PROTOTYPE within its window — a prototype has no body to
// analyze, so binding the marker to it leaves the REAL function below unchecked (a silent false
// GREEN). Before the fix, `// @spatial` bound to the get_u32 prototype and read_bad was never
// bounds-checked. funcHasBody excludes prototypes from coverage binding, so the marker falls
// through to the definition (or file-level) and the sink is checked.
unsigned get_u32(const unsigned char *p);

// @counted_by(buf: len)
int read_bad(const unsigned char *buf, unsigned len, unsigned i) {
  return (int)get_u32(buf + i + 1);   //EXPECT UNVALIDATED_INDEX
}
