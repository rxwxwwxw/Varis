local t = {}
for i = 1, 200000 do t["k" .. i] = i end
local s = 0
for rep = 1, 5 do for k, v in pairs(t) do s = s + v end end
local arr = {}
for i = 1, 500000 do arr[i] = i end
for rep = 1, 5 do for i, v in ipairs(arr) do s = s + v end end
for rep = 1, 5 do for i = 1, #arr do s = s + arr[i] end end
print(s)
