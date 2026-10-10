-- Spec §8, §11.7, §13.2: recursion over a negated lower stratum, evaluated in
-- two independent worlds.
--
-- A W x H grid of cells.  Column C is a wall.  Moves go between orthogonal
-- neighbours (both directions) unless the target is a wall cell.
--   world "gap":    the wall has an opening at row G -> every non-wall cell
--                   is reachable from (1,1): W*H - (H-1) cells.
--   world "sealed": no opening -> only the C-1 columns left of the wall:
--                   (C-1)*H cells.
-- Small: W=4, H=3, C=2, G=2:  gap 10 cells, sealed 3 cells.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { w = 4,  h = 3,  wall = 2,  gap = 2 },
    large = { w = 24, h = 20, wall = 12, gap = 7 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local W, H, C, G = P.w, P.h, P.wall, P.gap

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function count(iterator)
    local n = 0
    for _ in iterator do n = n + 1 end
    return n
end

-- The shared rules are registered in the empty world, then snapshotted into
-- both variants by inheritance.
local base = logic.emptyworld()
logic (base) do
    rule reach(?x, ?y) :- start(?x, ?y)
    rule reach(?a, ?b) :- reach(?x, ?y), move(?x, ?y, ?a, ?b), not wall(?a, ?b)
    fact start(1, 1)
end

-- Cell adjacency is a base relation of its own, in both worlds.
local function add_grid(world)
    for x = 1, W do
        for y = 1, H do
            if x < W then
                logic.add(world, "move", x, y, x + 1, y)
                logic.add(world, "move", x + 1, y, x, y)
            end
            if y < H then
                logic.add(world, "move", x, y, x, y + 1)
                logic.add(world, "move", x, y + 1, x, y)
            end
        end
    end
end
local gap, sealed = logic.world(base), logic.world(base)
add_grid(gap)
add_grid(sealed)

-- The wall: column C, with or without a gap.
for y = 1, H do
    fact sealed.wall(C, y)
    if y ~= G then fact gap.wall(C, y) end
end

expect("cells reachable through the gap", count(query gap.reach(?x, ?y)), W * H - (H - 1))
expect("cells reachable when sealed", count(query sealed.reach(?x, ?y)), (C - 1) * H)
expect("far corner via gap", count(query gap.reach(W, H)), 1)
expect("far corner when sealed", count(query sealed.reach(W, H)), 0)
expect("wall cell never reached", count(query gap.reach(C, 1)), 0)
expect("gap cell reached", count(query gap.reach(C, G)), 1)

-- Closing the gap at run time shrinks the reachable set again (negation:
-- adding to the negated relation removes derived tuples).
fact gap.wall(C, G)
expect("after closing the gap", count(query gap.reach(?x, ?y)), (C - 1) * H)
retract gap.wall(C, G)
expect("after reopening the gap", count(query gap.reach(?x, ?y)), W * H - (H - 1))
