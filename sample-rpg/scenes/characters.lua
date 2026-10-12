-- Characters and the stage they appear on. Slots and images are the player's concern
-- (presentation.json); the engine keeps who is on stage and in what state.

character player {
    name = "You", tag = :player,
    attributes = {outfit = {:casual, :sporty, :scholarly}, expression = {:neutral, :happy, :worried}},
    defaults = {outfit = :casual, expression = :neutral}
}
character odile {
    name = "Aunt Odile", tag = :odile,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}
character mara {
    name = "Mara Voss", tag = :mara,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}
character pell {
    name = "Archivist Pell", tag = :pell,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}
character tilly {
    name = "Tilly Marsh", tag = :tilly,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}
character hask {
    name = "Constable Hask", tag = :hask,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}
character dane {
    name = "Dane Whitlock", tag = :dane,
    attributes = {expression = {:neutral, :happy, :worried}},
    defaults = {expression = :neutral}
}

-- One stage scene per place: the background, and whoever works there. The walk effect plays
-- the scene for its destination; the player acknowledges its beats automatically.
scene stage_house {
    {kind=:background, tag=:house},
    {kind=:hide, character=:player},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind=:show, character=:odile, slot=:right},
    {kind="return"}
}
scene stage_square {
    {kind=:background, tag=:square},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:dane},
    {kind=:show, character=:hask, slot=:right},
    {kind="return"}
}
scene stage_market {
    {kind=:background, tag=:market},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind="return"}
}
scene stage_forge {
    {kind=:background, tag=:forge},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind=:show, character=:mara, slot=:right},
    {kind="return"}
}
scene stage_archive {
    {kind=:background, tag=:archive},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind=:show, character=:pell, slot=:right},
    {kind="return"}
}
scene stage_tavern {
    {kind=:background, tag=:tavern},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind=:show, character=:tilly, slot=:right},
    {kind="return"}
}
scene stage_docks {
    {kind=:background, tag=:docks},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind="return"}
}
scene stage_quarry {
    {kind=:background, tag=:quarry},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:show, character=:dane, slot=:right},
    {kind="return"}
}
scene stage_green {
    {kind=:background, tag=:green},
    {kind=:hide, character=:player},
    {kind=:hide, character=:odile},
    {kind=:hide, character=:mara},
    {kind=:hide, character=:pell},
    {kind=:hide, character=:tilly},
    {kind=:hide, character=:hask},
    {kind=:hide, character=:dane},
    {kind="return"}
}
