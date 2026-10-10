-- bench: 100k string-key hash stores, 500 distinct keys
local t = {}
for i = 1, 100000 do
  local k = "key_" .. tostring(i % 500)
  t[k] = i
end
for i = 0, 499 do assert(t["key_" .. i] == (i == 0 and 100000 or 99500 + i)) end
