-- Regression: analysis builds a second Lua state; the host's own io file handles must stay valid.
relation actor(1)
fact actor(:a)
storylet hello(?id)
    when {actor(?id)}
    title "Hello {id}"
    choice go effect do end end
end
narrative.seal("analysis-io-fixture-v1")
local session = narrative.new(logic.global)
session:seed(1)
local report = narrative.analyze(session, {depth = 2})
assert(report.nodes > 0)
assert(io.type(io.stdout) == "file", "io.stdout must still be a file after analysis")
assert(io.stdout:write("") == io.stdout, "file methods must still accept host handles")
local path = os.tmpname()
local f = assert(io.open(path, "w"))
assert(f:write("x"))
f:close()
assert(io.type(f) == "closed file")
os.remove(path)
