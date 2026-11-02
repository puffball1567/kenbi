void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  char *q = p;
  char *r = q;
  delete[] r;
  consume(p);   //EXPECT USE_AFTER_FREE
}
