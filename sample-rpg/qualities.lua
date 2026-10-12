-- Quality metadata. Values live in the keyed relation quality(entity, name, value).
-- The four stats run 0-100; training stops being offered a few points short of the cap.

quality.define(:strength, {initial = 15, minimum = 0, maximum = 100, label = "Strength"})
quality.define(:wits,     {initial = 15, minimum = 0, maximum = 100, label = "Wits"})
quality.define(:charm,    {initial = 15, minimum = 0, maximum = 100, label = "Charm"})
quality.define(:grit,     {initial = 15, minimum = 0, maximum = 100, label = "Grit"})
quality.define(:coins,    {initial = 5,  minimum = 0, maximum = 200, label = "Coins"})
quality.define(:stamina,  {initial = 10, minimum = 0, maximum = 10,  label = "Stamina"})
quality.define(:points,   {initial = 6,  minimum = 0, maximum = 6,   label = "Spare points", visible = false})
quality.define(:day,      {initial = 1,  minimum = 1, maximum = 10,  label = "Day"})
quality.define(:slot,     {initial = 1,  minimum = 1, maximum = 4,   label = "Time", visible = false})
quality.define(:trust,    {initial = 0,  minimum = -5, maximum = 5,  label = "Trust", visible = false})
quality.define(:fame,     {initial = 0,  minimum = 0, maximum = 10,  label = "Standing in town"})

-- Display labels (templates show these for symbols).
for sym, label in pairs {
    [:house] = "Aunt Odile's house", [:square] = "the town square", [:market] = "the market",
    [:forge] = "Mara's forge", [:archive] = "the archive", [:tavern] = "the Gilded Heron",
    [:docks] = "the docks", [:quarry] = "the old quarry", [:green] = "the Festival Green",
    [:mara] = "Mara", [:pell] = "Archivist Pell", [:odile] = "Aunt Odile", [:tilly] = "Tilly",
    [:hask] = "Constable Hask", [:dane] = "Dane Whitlock",
    [:strength] = "Strength", [:wits] = "Wits", [:charm] = "Charm", [:grit] = "Grit",
    [:whetstone] = "a whetstone", [:tonic] = "a bottle of tonic", [:ribbon] = "a festival ribbon",
    [:spectacles] = "a pair of spectacles", [:leverage] = "Mara's leverage trick",
    [:quarry_map] = "the quarry map", [:cache_ring] = "the signet ring",
    [:farm] = "farming folk", [:merchant] = "merchants", [:scholar] = "scholars",
    [:dock] = "dock folk", [:gentry] = "fallen gentry",
    [:nerdy] = "the bookish one", [:athletic] = "the athletic one", [:charming] = "the charmer",
    [:loner] = "the scrappy loner",
    [:night_owl] = "Night owl", [:early_riser] = "Early riser", [:stubborn] = "Stubborn",
    [:animal_friend] = "Animal friend", [:light_sleeper] = "Light sleeper", [:sweet_tooth] = "Sweet tooth",
    [:hero] = "the town's hero", [:smith] = "Mara's apprentice at the forge", [:scribe] = "second keeper of the archive",
    [:troupe] = "a place with the touring players", [:warden] = "a badge on the town watch",
    [:quiet] = "a quiet summer and a ticket home", [:spectator] = "watch from the crowd",
    [:carry_barrels] = "barrels", [:copy_ledgers] = "ledgers", [:greet_visitors] = "visitors", [:mind_the_ferry] = "the ferry",
    [:brewer] = "Old Brewer Gant", [:tailor] = "the tailor", [:dane_cousin] = "Dane's cousin",
} do
    narrative.name(sym, label)
end
narrative.formatter("nil", function() return "nothing" end)
