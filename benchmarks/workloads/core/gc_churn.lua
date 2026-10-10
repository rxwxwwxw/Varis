-- bench: allocation-heavy churn of small tables and strings
local keep = {}
for i = 1, 400000 do
  local t = {i, i + 1, name = "n" .. (i % 100)}
  if i % 100 == 0 then keep[#keep + 1] = t end
end
assert(#keep == 4000)
