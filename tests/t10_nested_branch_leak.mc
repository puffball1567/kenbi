# freed only on the innermost path of nested branches -> leak elsewhere
@mem demo::buf { free: free }
alloc p demo::buf
if
  if
    free p
  endif
endif
#EXPECT LEAK
