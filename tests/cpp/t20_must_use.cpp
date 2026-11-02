// @must_use
int probe();
int use() {
  int r = probe();  // consumed: assigned — ok
  (void)r;
  probe();          // dropped — declared @must_use   //EXPECT UNUSED_MUST_USE
  return 0;
}
