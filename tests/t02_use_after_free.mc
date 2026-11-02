# use after free
@mem demo::buf { free: free }
alloc p demo::buf
free p
use p
#EXPECT USE_AFTER_FREE
