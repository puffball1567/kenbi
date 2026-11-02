void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n, int c, int d) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];   //EXPECT LEAK
  if (c) {
    if (d) {
      delete[] p;
    }
  }
}
