-- Spec §3, §17: the new words are contextual, ? and : are told apart by
-- context, and declarative statements are free-form.
--
-- Benchmark: a chunk of F generated facts and rules is compiled with load()
-- and run, exercising the lexer, parser and compiler on declarative syntax.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { facts = 5 },
    large = { facts = 60000 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local F = P.facts

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function count(iterator)
    local n = 0
    for _ in iterator do n = n + 1 end
    return n
end

-- fact, rule, query, relation, retract and where are ordinary names.
local fact, rule, relation, retract, where = 12, "r", {}, function() return 1 end, true
local query = function(x) return x * 2 end
expect("local named fact", fact, 12)
expect("local named rule", rule, "r")
expect("function named query", query(21), 42)
expect("function named retract", retract(), 1)
expect("local named where", where, true)
local t = { fact = 1, rule = 2, query = 3, logic = 4 }
expect("fields named like keywords", t.fact + t.rule + t.query + t.logic, 10)
function t:where() return self.fact end
expect("method named where", t:where(), 1)

-- The real statements are still recognised from their complete forms, even
-- while locals with those names are in scope.
relation link(2)
fact link(:a, :b)
rule linked(?x, ?y) :- link(?x, ?y)
expect("declarations beside same-named locals", count(query linked(?x, ?y)), 1)
expect("call syntax still a call", query(4), 8)

-- ':' keeps all of its Lua meanings.
local object = { value = 5 }
function object:double() return self.value * 2 end
local s = :double
expect("method call and symbol", object:double(), 10)
expect("symbol is not the method", logic.symbolname(s), "double")
do
    local n = 0
    ::top::
    n = n + 1
    if n < 4 then goto top end
    expect("label and goto", n, 4)
end

-- Declarative statements do not depend on newlines or terminators.
fact edge(:a, :b) fact edge(:b, :c) rule reach(?x, ?y) :- edge(?x, ?y) rule reach(?x, ?y) :- edge(?x, ?z), reach(?z, ?y)
expect("everything on one line", count(query reach(?x, ?y)), 3);
-- Semicolons may separate them too, like ordinary statements.
fact edge(:c, :d); fact edge(:d, :e);
expect("with semicolons", count(query reach(:a, ?t)), 4)
-- A rule body may be spread over lines in any way.
rule far(?x, ?y) :-
    reach(?x, ?y)
    ,
    ?x ~= :a
expect("multi-line rule body", count(query far(?x, ?y)), 6)

-- Variables: each rule and query has its own scope, ?_ is always fresh.
expect("closure of the five-node chain", count(query reach(?x, ?y)), 10)
expect("repeated variable means equal", count(query edge(?x, ?x)), 0)
expect("each ?_ is distinct", count(query edge(?_, ?_)), 1)
fact edge(:loop, :loop)
expect("repeated variable finds the loop", count(query edge(?x, ?x)), 1)

-- Benchmark: generate source text with F facts and a rule, compile and run it.
local lines = { "relation num(1)", "relation even(1)" }
for i = 1, F do
    lines[#lines + 1] = "fact num(" .. i .. ")"
end
lines[#lines + 1] = "rule even(?n) :- num(?n), where (?n % 2 == 0)"
lines[#lines + 1] = "return query even(?n)"
local chunk = assert(load(table.concat(lines, "\n"), "=generated"))
expect("generated program result", count(chunk()), F // 2)
