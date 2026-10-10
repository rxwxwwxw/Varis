-- bench: gsub, find, format, rep, byte/char
local n = 0
for i = 1, 20000 do
  local s = string.format("item-%05d:%s", i, string.rep("x", i % 7))
  local t = s:gsub("%d+", function(d) return #d end)
  if t:find("item", 1, true) then n = n + #t end
  n = n + s:byte(1) + #string.char(65, 66, 67)
end
assert(n > 0)
