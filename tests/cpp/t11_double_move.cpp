void consume(void *p) noexcept;
void sink(void *p) noexcept;
void f(int n) {
  /* @mem demo::buf { free: delete, owner: p } */
  char *p = new char[n];
  sink(p);   // @move demo::buf
  sink(p);   // @move demo::buf   //EXPECT DOUBLE_MOVE
}
