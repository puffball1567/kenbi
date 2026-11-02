// Negative control: a @must_use result that is actually consumed — assigned,
// returned, passed as an argument, or tested in a condition — is clean.
// @must_use
int check_status(void);
void sink(int x);
int g(void) {
  int s = check_status();   // consumed: assigned
  sink(check_status());     // consumed: passed as argument
  if (check_status()) {     // consumed: tested
    s = s + 1;
  }
  return check_status();    // consumed: returned
}
