// @borrows(p)
void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];   //EXPECT LEAK
  consume(p);   // a declared borrow — not an escape; p stays owned -> leaks
}
