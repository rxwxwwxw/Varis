-- The project manifest (AUTHORING_TOOLS_PLAN §3.2). It is read, never executed.
return {
    id       = "saltmarsh",
    language = "en",
    entry    = "game",
    content  = { "content/*.lua", "qualities.lua" },
    scripts  = { "main.lua", "game.lua", "world.lua", "tools/*.lua" },
    session  = "game.new_session",
    after_choose = "game.sync_periods",   -- the host's step after every choice
    finished = "game.is_over",
    load     = "game.load",
    tests    = { "tests/*.lua" },
    locales  = {},
}
