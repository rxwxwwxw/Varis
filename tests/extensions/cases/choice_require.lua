-- A choice's `require` clause: presented disabled, with a reason and no token, when it fails.
quality.define(:str, {initial = 10, minimum = 0, maximum = 100, label = "Strength"})
storylet lift(?x)
    when { thing(?x) }
    title "Lift {x}"
    choice go
        require { quality(:player, :str, ?s), ?s >= 50 }
        because "Too weak to lift {x}."
        title "Heave"
        effect do adjust quality(:player, :str) by 1 end
    end
    choice shrug
        title "Shrug"
        effect do end
    end
end
local w = logic.world()
logic (w) do fact thing(:rock) end
quality.initialize(:player, :str, w)
local s = narrative.new(w)
s:seed(1)
local function by_id(p, id)
    local cs = p.storylets[1].choices
    for i = 1, #cs do if cs[i].id == id then return cs[i] end end
end
local go = by_id(s:present(), :go)
assert(go.enabled == false and go.token == nil and go.because == "Too weak to lift rock.")
assert(by_id(s:present(), :shrug).enabled == nil, "choices without require carry no enabled field")
reject(function() s:choose(go.token) end, "")
quality.set(:player, :str, 60, w)
go = by_id(s:present(), :go)
assert(go.enabled == true and go.because == "" and go.token ~= nil)
-- A token issued while the requirement held is refused once it stops holding.
quality.set(:player, :str, 20, w)
reject(function() s:choose(go.token) end, "STALE_CHOICE")
quality.set(:player, :str, 70, w)
s:choose(by_id(s:present(), :go).token)
assert(quality.get(:player, :str, w) == 71)
-- Saves are unaffected by the requirement's wording but not by its structure.
print("choice require passed")
