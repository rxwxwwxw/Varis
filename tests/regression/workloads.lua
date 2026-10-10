-- Small deterministic algorithmic workloads; their results and a checksum must match C Lua.
local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit = T.emit
-- n-body style float arithmetic
local function energy(bodies)
  local e = 0.0
  for i, b in ipairs(bodies) do
    e = e + 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy)
    for j = i + 1, #bodies do
      local c = bodies[j]
      local dx, dy = b.x - c.x, b.y - c.y
      e = e - b.mass * c.mass / math.sqrt(dx * dx + dy * dy)
    end
  end
  return e
end
local bodies = {}
for i = 1, 5 do bodies[i] = {x = i * 1.5, y = i * 0.7 - 2, vx = 0.1 * i, vy = -0.05 * i, mass = 1 + i * 0.3} end
emit("e0", energy(bodies))
for step = 1, 20000 do
  for i = 1, #bodies do
    local b = bodies[i]
    for j = i + 1, #bodies do
      local c = bodies[j]
      local dx, dy = b.x - c.x, b.y - c.y
      local d2 = dx * dx + dy * dy + 0.01
      local mag = 0.001 / (d2 * math.sqrt(d2))
      b.vx = b.vx - dx * c.mass * mag; b.vy = b.vy - dy * c.mass * mag
      c.vx = c.vx + dx * b.mass * mag; c.vy = c.vy + dy * b.mass * mag
    end
  end
  for _, b in ipairs(bodies) do b.x = b.x + 0.001 * b.vx; b.y = b.y + 0.001 * b.vy end
end
emit("e1", energy(bodies))
-- fannkuch(8)
local function fannkuch(n)
  local p, q, s, sign, maxflips, sum = {}, {}, {}, 1, 0, 0
  for i = 1, n do p[i] = i; q[i] = i; s[i] = i end
  repeat
    local q1 = p[1]
    if q1 ~= 1 then
      for i = 2, n do q[i] = p[i] end
      local flips = 1
      while true do
        local qq = q[q1]
        if qq == 1 then sum = sum + sign * flips; if flips > maxflips then maxflips = flips end; break end
        q[q1] = q1
        if q1 >= 4 then
          local i, j = 2, q1 - 1
          repeat q[i], q[j] = q[j], q[i]; i = i + 1; j = j - 1 until i >= j
        end
        q1 = qq; flips = flips + 1
      end
    end
    if sign == 1 then p[2], p[1] = p[1], p[2]; sign = -1
    else
      p[2], p[3] = p[3], p[2]; sign = 1
      for i = 3, n do
        local sx = s[i]
        if sx ~= 1 then s[i] = sx - 1; break end
        if i == n then return sum, maxflips end
        s[i] = i
        local t = p[1]; for j = 1, i do p[j] = p[j + 1] end; p[i + 1] = t
      end
    end
  until false
end
emit("fannkuch", fannkuch(8))
-- binary trees
local function bottomUp(d)
  if d == 0 then return {} end
  return {bottomUp(d - 1), bottomUp(d - 1)}
end
local function check(t) if t[1] then return 1 + check(t[1]) + check(t[2]) end return 1 end
local total = 0
for d = 4, 14, 2 do total = total + check(bottomUp(d)) end
emit("trees", total)
-- sieve + collatz + gcd
local sieve, count = {}, 0
for i = 2, 200000 do sieve[i] = true end
for i = 2, 447 do if sieve[i] then for j = i * i, 200000, i do sieve[j] = false end end end
for i = 2, 200000 do if sieve[i] then count = count + 1 end end
emit("primes", count)
local best, bestn = 0, 0
for n = 1, 30000 do
  local steps, x = 0, n
  while x ~= 1 do x = (x % 2 == 0) and x // 2 or 3 * x + 1; steps = steps + 1 end
  if steps > best then best, bestn = steps, n end
end
emit("collatz", bestn, best)
local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
local g = 0
for i = 1, 3000 do g = g + gcd(i * 7919, 104729 + i) end
emit("gcd", g)
-- string building and splitting
local parts = {}
for i = 1, 20000 do parts[#parts + 1] = string.format("%05d:%s", i * 37 % 10007, string.rep("ab", i % 5)) end
local joined = table.concat(parts, ";")
local n, len = 0, 0
for item in joined:gmatch("[^;]+") do n = n + 1; len = len + #item end
emit("strings", #joined, n, len)
-- matrix multiplication
local N = 60
local A, B, C = {}, {}, {}
for i = 1, N do A[i], B[i], C[i] = {}, {}, {} for j = 1, N do A[i][j] = (i * j) % 7 + 0.5; B[i][j] = (i + j) % 5 - 1.25 end end
for i = 1, N do for j = 1, N do local s = 0.0; for k = 1, N do s = s + A[i][k] * B[k][j] end; C[i][j] = s end end
emit("matrix", C[1][1], C[N][N], C[N // 2][N // 3])
T.done()
