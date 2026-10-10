-- csmith-style differential fuzzing: expressions are generated from a seeded private PRNG,
-- compiled with load(), evaluated under pcall, and every result or error message is hashed.
local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit = T.emit
local seed = tonumber(os.getenv('FUZZ_SEED') or '') or 20240607
local COUNT = tonumber(os.getenv('FUZZ_COUNT') or '') or 1500
local DEPTH = tonumber(os.getenv('FUZZ_DEPTH') or '') or 3
local function rnd(n) seed = (seed * 6364136223846793005 + 1442695040888963407); return ((seed >> 33) % n) + 1 end
local operands = {"0", "1", "-1", "2", "7", "255", "0.5", "-2.5", "1e10", "3.0", "math.maxinteger", "math.mininteger",
  "math.huge", "-math.huge", "'10'", "'0x1F'", "'  5  '", "'abc'", "''", "'1e2'", "nil", "true", "false", "2^53",
  "(2^63)", "t[1]", "t.k", "#t", "s", "-0.0"}
local binops = {"+", "-", "*", "/", "//", "%", "^", "&", "|", "~", "<<", ">>", "..", "==", "~=", "<", "<=", ">", ">=",
  "and", "or"}
local unops = {"-", "~", "not ", "#"}
local function gen(depth)
  if depth == 0 or rnd(4) == 1 then return operands[rnd(#operands)] end
  local k = rnd(10)
  if k <= 7 then
    return "(" .. gen(depth - 1) .. " " .. binops[rnd(#binops)] .. " " .. gen(depth - 1) .. ")"
  elseif k <= 9 then
    return "(" .. unops[rnd(#unops)] .. gen(depth - 1) .. ")"
  end
  return "math.type(" .. gen(depth - 1) .. ")"
end
local env = setmetatable({t = {10, k = "v"}, s = "str", math = math}, {__index = _G})
local errors, oks = 0, 0
for i = 1, COUNT do
  local src = "return " .. gen(DEPTH)
  local f, perr = load(src, "=expr", "t", env)
  if not f then
    emit("syntax", (perr:gsub("^[^:]*:%d+: ", "")))
  else
    local r = table.pack(pcall(f))
    if r[1] then
      oks = oks + 1
      if i % 7 == 0 then emit(i, src, r[2]) else emit(i, r[2]) end
    else
      errors = errors + 1
      if os.getenv("FUZZ_SHOW") == tostring(i) then print(src) end
      emit(i, "error", (tostring(r[2]):gsub("^[^:]*:%d+: ", "")))
    end
  end
end
emit("summary", oks, errors)
T.done()
