# cannot free an interior pointer; owner is freed separately
@mem demo::buf { size: n, free: free }
alloc p demo::buf
interior r p 16
free r
free p
#EXPECT FREE_INTERIOR
