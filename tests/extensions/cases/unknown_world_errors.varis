-- Extension regression: unknown_world_errors
local fake = {}
reject(function() fact fake.p(1) end, "expected world object")
reject(function() local q = query fake.p(?x) end, "expected world object")
reject(function() logic.world(fake) end, "expected world object")
reject(function() local q = query missing(?x) end, "unknown relation")
relation p(1) fact p(1)
assert(count(query p(?x)) == 1)
