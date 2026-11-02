void cleanup(int *p) { (void)p; }
void attribute_entry(void) {
  int p __attribute__((cleanup(cleanup))) = 1;
}
int asm_entry(void) { __asm__(""); return 1; }
