# leak: allocated, used, never freed
@mem demo::buf { free: free }
alloc p demo::buf
use p
#EXPECT LEAK
