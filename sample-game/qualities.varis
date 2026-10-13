-- Quality metadata (§11). Registered before sealing; values live in the
-- keyed relation quality(entity, name, value) of each session world.

quality.define(:coins,   {initial = 0,  minimum = 0, maximum = 99, label = "Coins"})
quality.define(:oil,     {initial = 3,  minimum = 0, maximum = 6,  label = "Lamp oil"})
quality.define(:resolve, {initial = 5,  minimum = 0, maximum = 10, label = "Resolve"})
quality.define(:trust,   {initial = 0,  minimum = -5, maximum = 5, label = "Keeper's trust"})
quality.define(:hour,    {initial = 18, minimum = 0, maximum = 24, visible = false})
quality.define(:day,     {initial = 1,  minimum = 1, maximum = 9,  label = "Day"})

-- Display labels used by templates (§10.1).
for sym, label in pairs {
    [:cottage] = "the keeper's cottage", [:shore] = "the shingle shore",
    [:village] = "Saltmarsh village",    [:market] = "the fish market",
    [:tower] = "the foot of the lighthouse", [:lamp_room] = "the lamp room",
    [:matches] = "a box of matches", [:oil_can] = "a can of lamp oil",
    [:brass_key] = "a brass key", [:rope] = "a coil of rope",
    [:bread] = "a heel of bread", [:spyglass] = "a spyglass",
    [:keeper] = "old Hesketh",
} do
    narrative.name(sym, label)
end
narrative.formatter("nil", function() return "nothing" end)
