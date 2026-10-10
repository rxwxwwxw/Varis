local t = {}
for i = 1, 100000 do t[#t + 1] = string.format("%d:%s:%5.2f", i, "x" .. i, i / 3) end
local s = table.concat(t, ",")
local n = 0
for w in s:gmatch("%d+:x%d+") do n = n + 1 end
local r = s:gsub("x(%d+)", "<%1>")
print(#s, n, #r, s:find("99999:", 1, true), s:upper():sub(1, 10), s:rep(2):len())
local parts = {}
for k, v in s:gmatch("(%d+):x(%d+)") do parts[#parts+1] = k + v end
print(#parts)
