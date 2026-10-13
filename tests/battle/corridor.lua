-- A small headless battle for `varis battle` and its test: one open lane, three bolt towers.
-- Sectors are 16 x 9 tiles, so a 32 x 9 map is two sectors.
local setup = {
    seed = 3, map_seed = 5, width = 32, height = 9, wall_density = 0, attack_every = 1,
    credits = 100, max_leaks = 5, structure_room = 10,
    revealed = {1, 2},
    sinks = {{q = 30, r = 4}},
    sources = {{q = 1, r = 4, sink = 1}},
    towers = {{name = "bolt", cost = 10, range = 3, damage = 4, cooldown = 3, hp = 30, ability = "single"}},
    enemies = {{name = "dimling", hp = 12, speed = 512, armour = 0, bounty = 1, structure_damage = 1}},
    waves = {{source = 1, kind = 1, count = 6, every = 6, start = 0}},
}
return setup, function(h)
    for q = 8, 20, 6 do assert(h:place(1, q, 5)) end
end
