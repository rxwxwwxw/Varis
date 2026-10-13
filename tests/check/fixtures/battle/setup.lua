-- Each table below has exactly one mistake the battle checks must find, with its source position.
return {
    towers = {
        {name = "ok", cost = 10, range = 2, damage = 3, cooldown = 2, hp = 20, ability = "single"},
        {name = "spell", cost = 10, range = 2, damage = 3, cooldown = 2, hp = 20, ability = "sigle"},
        {name = "nohp", cost = 10, range = 2, damage = 3, cooldown = 2, ability = "splash"},
    },
    moments = {
        {id = 1, trigger = "wave_start", arg = 1, scene = "found"},
        {id = 2, trigger = "wave_strat", arg = 1, scene = "found"},
        {id = 3, trigger = "step", arg = 5, scene = "missing_scene"},
        {id = 4, trigger = "hero_hp_below", arg = 9001, arg2 = 140, scene = "found"},
        {id = 5, trigger = "leak_count", arg = 0, scene = "found"},
    },
}
