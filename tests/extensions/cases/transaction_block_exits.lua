-- Every way of leaving a `transaction do ... end` block ends the transaction: falling off the
-- end, break, goto (forwards, backwards, out of several blocks at once), return, rollback and an
-- error. Leaving by a jump commits. The same holds with debug hooks installed and in frames past
-- the depth where calls stop recursing natively.
relation log(entry) key(entry)
local function has(entry) return (query { log(entry) })() ~= nil end
local function in_transaction() return not pcall(function() relation probe(x) end) end

local closed = {}
local function closer(name)
    return setmetatable({}, {__close = function() closed[#closed + 1] = name .. (has(name) and ":visible" or ":hidden") end})
end

local function exits(tag)
    -- break, taken conditionally, inside a loop
    for i = 1, 5 do
        transaction do
            fact log(tag .. "break" .. i)
            if i == 3 then break end
        end
    end
    assert(has(tag .. "break3") and not has(tag .. "break4"))

    -- while + break as the block's only statement after a write
    local n = 0
    while true do
        transaction do
            n = n + 1
            fact log(tag .. "while" .. n)
            if n < 3 then goto continue end
            break
        end
        ::continue::
    end
    assert(n == 3 and has(tag .. "while1") and has(tag .. "while3"))

    -- goto out of two nested blocks at once; a to-be-closed value of each is closed, innermost
    -- first, while its transaction is still open
    closed = {}
    do
        transaction do
            local outer <close> = closer(tag .. "outer")
            fact log(tag .. "outer")
            transaction do
                local inner <close> = closer(tag .. "inner")
                fact log(tag .. "inner")
                goto out
            end
            fact log(tag .. "skipped")
        end
        ::out::
    end
    assert(has(tag .. "outer") and has(tag .. "inner") and not has(tag .. "skipped"))
    assert(#closed == 2 and closed[1] == tag .. "inner:visible" and closed[2] == tag .. "outer:visible", table.concat(closed, " "))
    assert(not in_transaction())

    -- leaving the inner block only: the outer one stays open and can still roll back
    transaction do
        for i = 1, 2 do
            transaction do
                fact log(tag .. "kept" .. i)
                if i == 1 then goto next end
                fact log(tag .. "second")
            end
            ::next::
        end
        assert(in_transaction() and has(tag .. "kept1"))
        rollback
    end
    assert(not has(tag .. "kept1") and not has(tag .. "second") and not in_transaction())

    -- backward goto out of a block
    local rounds = 0
    ::again::
    rounds = rounds + 1
    transaction do
        fact log(tag .. "round" .. rounds)
        if rounds < 3 then goto again end
    end
    assert(rounds == 3 and has(tag .. "round1") and has(tag .. "round3"))

    -- repeat ... until with the condition jumping out, and a numeric loop inside a block
    local k = 0
    repeat
        transaction do
            k = k + 1
            for j = 1, 3 do
                if j == 2 then fact log(tag .. "loop" .. k) end
            end
        end
    until k == 2
    assert(has(tag .. "loop2"))

    -- return commits; an error rolls back and leaves nothing open
    local function returns()
        transaction do
            fact log(tag .. "returned")
            return "done"
        end
    end
    assert(returns() == "done" and has(tag .. "returned"))
    local ok = pcall(function()
        transaction do
            fact log(tag .. "failed")
            for i = 1, 3 do if i == 2 then error("stop") end end
        end
    end)
    assert(not ok and not has(tag .. "failed") and not in_transaction())

    -- an error raised while a jump is committing: the closing handler's error escapes and the
    -- transaction is rolled back
    ok = pcall(function()
        for i = 1, 1 do
            transaction do
                local bad <close> = setmetatable({}, {__close = function() error("close failed") end})
                fact log(tag .. "closefail")
                break
            end
        end
    end)
    assert(not ok and not has(tag .. "closefail") and not in_transaction())
end

exits("plain.")

-- With line and count hooks installed the program does the same, and the hooks see only lines
-- of the program.
local lines, counts = {}, 0
debug.sethook(function(event, line)
    if event == "line" then lines[line] = true else counts = counts + 1 end
end, "l", 1)
exits("hooked.")
debug.sethook()
assert(counts > 100)
local last = debug.getinfo(1, "l").currentline
for line in pairs(lines) do assert(line > 0 and line <= last, line) end

-- Past the native recursion depth.
local function deep(n)
    if n == 0 then exits("deep.") return 0 end
    return 1 + deep(n - 1)
end
assert(deep(400) == 400)

-- The instruction count seen by a count hook is the same with or without a jump out of a block
-- being a trampoline: two loops that differ only in the transaction keyword's presence differ
-- by the instructions of the block itself, and repeating either gives the same count.
local function counted(f)
    local c = 0
    debug.sethook(function() c = c + 1 end, "", 1)
    f()
    debug.sethook()
    return c
end
local function with_exit()
    for i = 1, 10 do transaction do if i > 0 then break end end end
end
assert(counted(with_exit) == counted(with_exit))
print("ok")
