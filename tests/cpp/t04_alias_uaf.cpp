void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  char *q = p;
  delete[] q;
  consume(p);   //EXPECT USE_AFTER_FREE
}
