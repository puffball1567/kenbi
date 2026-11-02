void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { size: n, free: delete, owner: p } */
  char *p = new char[n];
  char *r = p + 4;
  char *s = r + 8;
  delete[] p;
  consume(s);   //EXPECT USE_AFTER_FREE
}
