# freed on one path, then freed again after the join -> double free on that path
@mem demo::buf { free: free }
alloc p demo::buf
if
  free p
else
  use p
endif
free p
#EXPECT DOUBLE_FREE
