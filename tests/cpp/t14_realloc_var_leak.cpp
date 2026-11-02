// @nothrow(new)   allocation failure terminates: a plain `new` is not an unwinding exit
void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];   //EXPECT LEAK
  p = new char[n];
  delete[] p;
}
