// @must_use
int check_status(void);
void f(void) {
  check_status();   // result dropped — declared @must_use   //EXPECT UNUSED_MUST_USE
}
