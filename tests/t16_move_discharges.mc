# move discharges the obligation: no leak even though never freed here
@mem demo::buf { free: free }
alloc p demo::buf
move p
