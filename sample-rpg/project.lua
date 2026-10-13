-- The project manifest of The Hollowbrook Summer. It is read, never executed.
return {
    id       = "hollowbrook",
    language = "en",
    entry    = "game",
    content  = { "content/*.varis", "scenes/*.varis", "qualities.varis" },
    scripts  = { "main.lua", "game.lua", "world.lua", "tools/*.lua", "locales/*.lua" },
    session  = "game.new_session",
    finished = "game.is_over",
    load     = "game.load",
    tests    = { "tests/*.lua" },
    locales  = { "fr" },
}
