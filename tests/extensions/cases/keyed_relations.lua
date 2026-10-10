relation location(entity, room) key(entity)
relation score(value, entity, name) key(name, entity)
relation mark()
fact mark()
fact location(:player, :hall)
fact location(:player, :hall)
reject(function() fact location(:player, :garden) end, "conflicting fact")
local old = query location(:player, ?room)
set location(:player, :garden)
assert(old().room == :hall)
assert((query location(:player, ?room))().room == :garden)
set score(5, nil, :coins)
adjust score(:coins, nil) by 3
assert((query score(?value, nil, :coins))().value == 8)
reject(function() adjust score(:missing, nil) by 1 end, "adjust key is absent")
reject(function() adjust score(:coins, nil) by "2" end, "requires numeric values")
reject(function() set score(0/0, nil, :coins) end, "NaN is prohibited")
assert((query score(?value, nil, :coins))().value == 8)
local child = logic.world()
set child.location(:player, :library)
assert((query child.location(:player, ?room))().room == :library)
assert((query location(:player, ?room))().room == :garden)
delete score(:coins, nil)
delete score(:coins, nil)
assert((query score(?value, nil, :coins))() == nil)
reject(function() set mark() end, "not keyed")
reject(function() relation duplicate(a, a) key(a) end, "duplicate column")
reject(function() relation invalid(a, b) key(c) end, "unknown key column")
reject(function() relation location(entity, room) key(room) end, "conflicting schema")
relation location(entity, room) key(entity)
reject(function() rule location(?x, ?y) :- location(?x, ?y) end, "cannot be a rule head")
local key = symbol("binary\0key")
set location(key, nil)
assert((query location(key, ?room))().room == nil)
set location(1, :one)
reject(function() fact location(1.0, :two) end, "conflicting fact")
set location(1.0, :two)
assert((query location(1, ?room))().room == :two)
local count = 0
for row in query location(?entity, ?room) do count = count + 1 end
assert(count == 3)
local set, delete, adjust, transaction, rollback = function() return 1 end, function() return 2 end, function() return 3 end, function() return 4 end, 5
assert(set() + delete() + adjust() + transaction() + rollback == 15)

-- Sugar calls must retain their ordinary identifier meaning.
local seen = 0
rollback = function(value) seen = seen + 1 end
rollback "text"
rollback { value = 1 }
assert(seen == 2)
relation single(id) key(id)
set single(nil)
reject(function() adjust single(nil) by 1 end, "one non-key column")
relation many(id, x, y) key(id)
set many(:p, 1, 2)
reject(function() adjust many(:p) by 1 end, "one non-key column")
reject(function() delete many() end, "expects 1 key arguments")
reject(function() set many(:p) end, "expects arity 3")
local evaluations = 0
local function once() evaluations = evaluations + 1; return 7, 100 end
set many(:p, once(), once())
assert(evaluations == 2)
assert((query many(:p, ?x, ?y))().x == 7)
