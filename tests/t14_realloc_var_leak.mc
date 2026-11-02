# rebinding p to a fresh allocation leaks the first one
@mem demo::buf { free: free }
alloc p demo::buf
alloc p demo::buf
free p
#EXPECT LEAK
