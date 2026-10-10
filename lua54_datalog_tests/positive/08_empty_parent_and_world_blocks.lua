-- PASS: empty worlds, explicit parent snapshots, nested lexical world blocks.
relation mark(1)
fact mark(:global)

local parent = logic.emptyworld()
logic (parent) do
    relation mark(1)
    relation flagged(1)
    fact mark(:parent)
    rule flagged(?x) :- mark(?x)
end

local child = logic.world(parent)
logic (parent) do
    fact mark(:late_parent)
    logic (child) do
        fact mark(:child)
    end
    -- Default world is restored to parent here.
    fact mark(:after_child_block)
end

local function check(iter, expected)
    local count = 0
    for m in iter do
        assert(expected[m.x], "unexpected member of world")
        expected[m.x] = nil
        count = count + 1
    end
    assert(count > 0 and next(expected) == nil)
end

check(query mark(?x), {[:global] = true})
check(query parent.flagged(?x), {
    [:parent] = true, [:late_parent] = true, [:after_child_block] = true
})
check(query child.flagged(?x), {[:parent] = true, [:child] = true})
print("PASS 08_empty_parent_and_world_blocks")
