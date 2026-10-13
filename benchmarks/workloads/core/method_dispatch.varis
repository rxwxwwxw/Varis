-- bench: method calls and small-object creation through a metatable
local Point = {}; Point.__index = Point
function Point.new(x, y) return setmetatable({x = x, y = y}, Point) end
function Point:add(o) return Point.new(self.x + o.x, self.y + o.y) end
function Point:len2() return self.x * self.x + self.y * self.y end
local p = Point.new(0, 0); local d = Point.new(1, 2)
local s = 0
for i = 1, 500000 do p = p:add(d); s = s + p:len2() % 7 end
assert(p.x == 500000 and p.y == 1000000)
