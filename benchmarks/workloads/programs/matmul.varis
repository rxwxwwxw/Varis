local n = 70
local function mk(n, f) local m = {} for i = 1, n do local r = {} for j = 1, n do r[j] = f(i, j) end m[i] = r end return m end
local a, b = mk(n, function(i, j) return i + j end), mk(n, function(i, j) return i - j end)
local c = mk(n, function() return 0 end)
for i = 1, n do local ai, ci = a[i], c[i] for k = 1, n do local aik, bk = ai[k], b[k] for j = 1, n do ci[j] = ci[j] + aik * bk[j] end end end
print(c[1][1], c[n][n])
