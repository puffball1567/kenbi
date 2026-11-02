# transitive alias: p -> q -> r, free r, then use p
@mem demo::buf { free: free }
alloc p demo::buf
copy q p
copy r q
free r
use p
#EXPECT USE_AFTER_FREE
