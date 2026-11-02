# clean: allocate, use, free once. No issues expected.
@mem demo::buf { free: free }
alloc p demo::buf
use p
free p
