// Advisory: lock acquire/release effects + caller obligation. The engine does
// not decide these; they are surfaced for the reviewer (sparse-style contracts).
// @requires_lock(g_lock)   //EXPECT REQUIRES_LOCK
// @acquires(g_lock)   //EXPECT ACQUIRES
void lock_it(void);

// @releases(g_lock)   //EXPECT RELEASES
void unlock_it(void);
