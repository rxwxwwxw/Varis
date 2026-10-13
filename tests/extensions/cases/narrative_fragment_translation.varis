-- A translation may use {>fragment}: the registry expands it when the translation is registered.
relation ready(0)
fact ready()
narrative.fragment(:sign_off, "Fair winds.")
narrative.fragment(:sign_off_fr, "Bon vent.")
storylet quay()
    when { ready() }
    title "Quay"
    text "Nod. {>sign_off}"
    choice go effect do end end
end
narrative.seal()
narrative.translate("fr", {["quay.text"] = "Salut. {>sign_off_fr}"})
local s = narrative.new(logic.world())
s:seed(1)
local p = s:present()
assert(p.storylets[1].text == "Nod. Fair winds.")
assert(s:render(p, "fr").storylets[1].text == "Salut. Bon vent.", s:render(p, "fr").storylets[1].text)
reject(function() narrative.translate("fr", {["quay.text"] = "{>nothing}"}) end, "unknown template fragment")
