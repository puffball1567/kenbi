# use after free via an alias (q = p, free q, then use p)
@mem demo::buf { free: free }
alloc p demo::buf
copy q p
free q
use p
#EXPECT USE_AFTER_FREE
