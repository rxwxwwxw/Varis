-- Tower, hero-ability and enemy kinds of Lanternfall. Plain literal tables: the simulation reads
-- them through the battle bridge, and a mod changes the game by editing them. Kind numbers are
-- positions (1-based); the comments name them for the other files.
--
-- An ability is one of the ten primitives: single, splash, slow, chain, burn, aura, shield,
-- summon, repair, taunt. `buildable = false` kinds are used only by heroes and the story.

return {
    towers = {
        -- the lantern towers the warden builds (1-5)
        {name = "bolt",   cost = 10, range = 3, damage = 5, cooldown = 3, hp = 30, ability = "single"},
        {name = "chime",  cost = 22, range = 3, damage = 3, cooldown = 4, hp = 30, ability = "splash", radius = 1},
        {name = "hoar",   cost = 18, range = 3, damage = 1, cooldown = 4, hp = 30, ability = "slow", duration = 30},
        {name = "arc",    cost = 34, range = 3, damage = 4, cooldown = 4, hp = 30, ability = "chain", radius = 2, jumps = 3},
        {name = "beacon", cost = 28, range = 0, damage = 0, cooldown = 1, hp = 40, ability = "aura", radius = 3, power = 25},
        -- hero weapon and abilities (6-11), never on the build palette
        {name = "sling",  cost = 0, range = 3, damage = 2, cooldown = 5, hp = 1, ability = "single", buildable = false},
        {name = "repair", cost = 0, range = 0, damage = 0, cooldown = 160, hp = 1, ability = "repair", radius = 3, power = 14, buildable = false},
        {name = "taunt",  cost = 0, range = 0, damage = 0, cooldown = 300, hp = 1, ability = "taunt", radius = 3, duration = 100, buildable = false},
        {name = "flare",  cost = 0, range = 8, damage = 0, cooldown = 400, hp = 1, ability = "burn", radius = 2, duration = 60, power = 2, reveal = 1, buildable = false},
        {name = "ward",   cost = 0, range = 0, damage = 0, cooldown = 120, hp = 1, ability = "shield", radius = 3, power = 14, buildable = false},
        {name = "rally",  cost = 0, range = 0, damage = 0, cooldown = 1, hp = 1, ability = "aura", radius = 3, power = 20, buildable = false},
        -- fixed structures and allies (12-14)
        {name = "bellfrey", cost = 0, range = 0, damage = 0, cooldown = 1, hp = 160, ability = "aura", radius = 4, power = 15, buildable = false},
        {name = "mill",     cost = 0, range = 0, damage = 0, cooldown = 80, hp = 120, ability = "shield", radius = 3, power = 10, buildable = false},
        {name = "militia",  cost = 0, range = 2, damage = 3, cooldown = 4, hp = 20, ability = "single", buildable = false},
        -- the abilities trust improves (15-16): a wider flare, a stronger repair
        {name = "flare_wide",     cost = 0, range = 8, damage = 0, cooldown = 400, hp = 1, ability = "burn", radius = 3, duration = 60, power = 2, reveal = 1, buildable = false},
        {name = "repair_strong",  cost = 0, range = 0, damage = 0, cooldown = 160, hp = 1, ability = "repair", radius = 3, power = 22, buildable = false},
    },
    enemies = {
        {name = "dimling", hp = 22,  speed = 56,  armour = 0, bounty = 2, structure_damage = 1},
        {name = "hound",   hp = 12,  speed = 112, armour = 0, bounty = 2, structure_damage = 1},
        {name = "husk",    hp = 60,  speed = 40,  armour = 2, bounty = 4, structure_damage = 3},
        {name = "wraith",  hp = 40,  speed = 44,  armour = 0, bounty = 6, structure_damage = 2,
            shield = 15, summon = 1, summon_every = 80, summon_cap = 2},
        {name = "maw",     hp = 900, speed = 28,  armour = 2, bounty = 60, structure_damage = 8,
            burn_radius = 2, burn_power = 3, burn_every = 20},
    },
}
