-- Shared harness for the regression programs: every observable value is printed and folded
-- into a 64-bit FNV-1a checksum (as in csmith-style differential testing), so two
-- implementations agree only if every line they produce agrees.
local M = {}
local H = 0xcbf29ce484222325
local lines = 0

local function feed(s)
  for i = 1, #s do H = (H ~ s:byte(i)) * 0x100000001b3 end
end

local function show(v)
  local t = math.type(v)
  if t == "integer" then return string.format("%d", v) end
  if t == "float" then
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" elseif v == -math.huge then return "-inf" end
    return string.format("%.17g", v)
  end
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" or type(v) == "function" or type(v) == "thread" or type(v) == "userdata" then
    return type(v)
  end
  return tostring(v)
end
M.show = show

function M.emit(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = show((select(i, ...))) end
  local line = table.concat(parts, "\t")
  print(line)
  feed(line)
  feed("\n")
  lines = lines + 1
end

-- Runs f(...) in protected mode and emits "ok" plus results or "err" plus the message.
function M.try(f, ...)
  local r = table.pack(pcall(f, ...))
  if r[1] then M.emit("ok", table.unpack(r, 2, r.n))
  else M.emit("err", r[2]) end
end

function M.done()
  print(string.format("CHECKSUM %016x lines %d", H, lines))
end

return M
