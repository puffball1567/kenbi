/* Independently authored shared-callee depth regression. */
void shared(void) {}
void deeper(void) { shared(); }
void memo_root(void) { shared(); deeper(); }
