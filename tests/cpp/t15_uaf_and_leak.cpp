void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n, int c) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];   //EXPECT LEAK
  if (c) {
    delete[] p;
  }
  consume(p);   //EXPECT USE_AFTER_FREE
}
