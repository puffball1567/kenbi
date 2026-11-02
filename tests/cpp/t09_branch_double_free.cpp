// @borrows(p)
void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n, int c) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  if (c) {
    delete[] p;
  } else {
    consume(p);   // borrow only -> p still owned on this path
  }
  delete[] p;       // double free on the then-path (already freed at line 9)   //EXPECT DOUBLE_FREE
}
