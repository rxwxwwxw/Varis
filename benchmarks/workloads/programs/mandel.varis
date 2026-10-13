local N = 160
local count = 0
for y = 0, N - 1 do
  for x = 0, N - 1 do
    local cr, ci = 2.0 * x / N - 1.5, 2.0 * y / N - 1.0
    local zr, zi = 0.0, 0.0
    local inside = true
    for i = 1, 50 do
      local zr2, zi2 = zr * zr, zi * zi
      if zr2 + zi2 > 4.0 then inside = false; break end
      zi = 2.0 * zr * zi + ci; zr = zr2 - zi2 + cr
    end
    if inside then count = count + 1 end
  end
end
print(count)
