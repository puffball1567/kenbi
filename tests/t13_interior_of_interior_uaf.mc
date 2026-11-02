# interior of an interior pointer still tracks back to the same origin
@mem demo::buf { size: n, free: free }
alloc p demo::buf
interior r p 4
interior s r 8
free p
use s
#EXPECT USE_AFTER_FREE
