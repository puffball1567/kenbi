# move the owner, then use an interior pointer derived from it
@mem demo::buf { free: free }
alloc p demo::buf
interior r p 8
move p
use r
#EXPECT USE_AFTER_MOVE
