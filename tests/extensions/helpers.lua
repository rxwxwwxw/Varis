-- Shared assertions prepended by run-tests.py; every case runs in a fresh process.
local function count(iterator)
    local n = 0
    for _ in iterator do n = n + 1 end
    return n
end
local function reject(fn, diagnostic)
    local ok, err = pcall(fn)
    assert(not ok, "expected rejection containing: " .. diagnostic)
    assert(string.find(tostring(err), diagnostic, 1, true),
           "wrong rejection: " .. tostring(err) .. "; expected: " .. diagnostic)
end
