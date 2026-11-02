# double free
@mem demo::buf { free: free }
alloc p demo::buf
free p
free p
#EXPECT DOUBLE_FREE
