/* Synthetic API: independently authored, no device or vendor source. */
extern void normal_api(void);
extern void shared_api(void);
extern void wait_api(void);
extern void allocate_api(void);
extern void unknown_api(void);
void pure(void) {}
void normal_helper(void) { normal_api(); } // CONTEXT_EXPECT FORBIDDEN_CONTEXT_CALL
void indirect_normal(void) { normal_helper(); }
void shared(void) { shared_api(); }
void waiting(void) { wait_api(); } // CONTEXT_EXPECT FORBIDDEN_EFFECT
void allocating(void) { allocate_api(); } // CONTEXT_EXPECT FORBIDDEN_EFFECT
void missing(void) { unknown_api(); } // CONTEXT_EXPECT MISSING_CONTEXT_CONTRACT
void indirect(void (*callback)(void)) { callback(); }
void recursive(int n) { if (n) recursive(n - 1); shared_api(); }
void declared_body(void) { normal_helper(); }
void body_allocates(void) { allocate_api(); }
void body_pure(void) {}
