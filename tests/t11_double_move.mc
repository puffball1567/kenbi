# moving the same owner twice
@mem demo::buf { free: free }
alloc p demo::buf
move p
move p
#EXPECT DOUBLE_MOVE
