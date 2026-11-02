// Advisory: declared lock orders. Two declarations that disagree (A<B and B<A)
// are a pairwise deadlock — flagged deterministically but kept advisory.
// @lock_order(A < B)   //EXPECT LOCK_ORDER
void f(void);
// @lock_order(B < A)   //EXPECT LOCK_ORDER LOCK_ORDER_CONFLICT
void g(void);
