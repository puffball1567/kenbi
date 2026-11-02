void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  delete[] p;
  consume(p);   //EXPECT USE_AFTER_FREE
}
