# freeing on BOTH paths is clean (no false double-free, no leak)
@mem demo::buf { free: free }
alloc p demo::buf
if
  free p
else
  free p
endif
