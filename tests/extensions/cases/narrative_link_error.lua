-- A link naming no choice is rejected when the content is sealed.
relation ready(0)
fact ready()
storylet linked()
    when { ready() }
    title "Linked"
    text "Go [[there->nowhere]]."
    choice here effect do end end
end
local ok, err = pcall(narrative.seal)
assert(not ok and tostring(err):find("names no choice 'nowhere'", 1, true), tostring(err))
