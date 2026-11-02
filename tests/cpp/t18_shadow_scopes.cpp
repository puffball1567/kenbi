// @nothrow(new)   allocation failure terminates: a plain `new` is not an unwinding exit
void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  { char *p = new char[n]; delete[] p; }   // inner shadow, freed
  delete[] p;                              // outer
}
