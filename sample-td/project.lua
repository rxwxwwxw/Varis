-- The project manifest of Lanternfall. It is read, never executed. The four battle hooks
-- (TOWER_DEFENSE_PLAN.md §5.1) name module functions; the host resolves them like after_choose.
return {
    id       = "lanternfall",
    language = "en",
    entry    = "game",
    content  = { "content/*.varis", "scenes/*.varis", "qualities.varis", "battle/kinds.varis" },
    scripts  = { "main.lua", "game.lua", "world.lua", "battle/*.lua", "tools/*.lua" },
    session  = "game.new_session",
    load     = "game.load",
    finished = "game.is_over",
    tests    = { "tests/*.lua" },
    locales  = { "fr" },
    battle_request = "game.battle_request",
    battle_setup   = "game.battle_setup",
    battle_sync    = "game.battle_sync",
    battle_result  = "game.battle_result",
}
