-- Milestone 28: `symbols a, b, c` declares symbols; it is a declaration, not a statement that
-- does anything, and an ordinary variable called `symbols` still works.
symbols player, keeper, lamp_room
symbols resolve
local symbols = {1, 2}
assert(#symbols == 2)
symbols = nil
assert(symbols == nil)
local ok, message = load("symbols a,\n b\nreturn 1")
assert(ok and ok() == 1)
ok, message = load("symbols 1")
assert(not ok)
