# freed on one path, used after the join: UAF on one path, leak on the other
@mem demo::buf { free: free }
alloc p demo::buf
if
  free p
endif
use p
#EXPECT USE_AFTER_FREE
#EXPECT LEAK
