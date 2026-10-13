-- The waves of each night: {source, kind, count, every, start} (steps; 20 steps are one second).
-- Source 1 is the road below the terraces; source 2 is the east road, from night 3. Kinds are
-- positions in battle/kinds.lua: 1 dimling, 2 hound, 3 husk, 4 wraith, 5 maw.

return {
    [1] = {
        {source = 1, kind = 1, count = 12, every = 24, start = 0},
        {source = 1, kind = 2, count = 2,  every = 60, start = 100},
    },
    [2] = {
        {source = 1, kind = 1, count = 36, every = 9, start = 0},
        {source = 1, kind = 3, count = 10, every = 50, start = 120},
        {source = 1, kind = 2, count = 10, every = 30, start = 200},
    },
    [3] = {
        {source = 1, kind = 1, count = 60, every = 7,  start = 0},
        {source = 1, kind = 3, count = 20, every = 30, start = 100},
        {source = 1, kind = 4, count = 6,  every = 90, start = 300},
        {source = 2, kind = 1, count = 30, every = 16, start = 150},
        {source = 2, kind = 3, count = 14, every = 36, start = 360},
    },
    -- the Maw is the third wave: the moment "wave_start(3)" is its arrival
    [4] = {
        {source = 1, kind = 1, count = 70, every = 6,  start = 0},
        {source = 1, kind = 3, count = 24, every = 26, start = 80},
        {source = 1, kind = 5, count = 1,  every = 1,  start = 600},
        {source = 1, kind = 4, count = 8,  every = 70, start = 250},
        {source = 1, kind = 2, count = 20, every = 16, start = 150},
        {source = 2, kind = 1, count = 32, every = 16, start = 120},
        {source = 2, kind = 3, count = 16, every = 36, start = 300},
    },
}
