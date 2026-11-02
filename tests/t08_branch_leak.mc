# freed only on one path -> leak on the other (may-set join)
@mem demo::buf { free: free }
alloc p demo::buf
if
  free p
else
  use p
endif
#EXPECT LEAK
