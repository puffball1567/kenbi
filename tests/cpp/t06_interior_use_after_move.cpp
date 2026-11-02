void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  char *r = p + 8;
  sink(p);   // @move demo::buf
  consume(r);   //EXPECT USE_AFTER_MOVE
}
