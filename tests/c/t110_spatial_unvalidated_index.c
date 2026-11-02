// @spatial
// SPATIAL (bounds) axis: an untrusted scalar parameter used as an array index with
// no runtime bound check present is UNVALIDATED_INDEX (default-red). kenbi requires a
// check to EXIST on the path; it does not prove one unnecessary in order to remove it.
// The `@spatial` opt-in is independent of `@kenbi`.
extern int buf[256];

void use_index(int idx) {
  buf[idx] = 0;   // no bound on idx   //EXPECT UNVALIDATED_INDEX
}
