-- bench: pcall + error round trips (known cost centre: D exception unwinding)
local n = 0
for i = 1, 50000 do
  local ok, e = pcall(error, "boom")
  if not ok and e == "boom" then n = n + 1 end
end
assert(n == 50000)
for i = 1, 100000 do assert(pcall(function() return i end)) end
