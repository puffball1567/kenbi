// @spatial
// The same index becomes safe once a runtime bound check is present on the path.
// Both the if-guard (then-branch) and the early-return guard validate `idx`; this
// file carries no expectation marker, so it must be CLEAN (GREEN).
extern int buf[256];

void guarded(unsigned int idx) {
  if (idx < 256) {
    buf[idx] = 0;          // validated by the then-branch bound
  }
}

void early_return(unsigned int idx) {
  if (idx >= 256) return;  // bound the value, fall through validated
  buf[idx] = 0;
}
