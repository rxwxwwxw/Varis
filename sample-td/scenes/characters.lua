-- Characters and the stage they appear on. Slots and images are the player's concern
-- (presentation.json); the engine keeps who is on stage and in what state.

character warden {
    name = "The Warden", tag = :warden,
    attributes = {expression = {:calm, :worried}},
    defaults = {expression = :calm}
}
character ilse {
    name = "Ilse", tag = :ilse,
    attributes = {expression = {:calm, :worried, :fierce}},
    defaults = {expression = :calm}
}
character corvin {
    name = "Corvin", tag = :corvin,
    attributes = {expression = {:calm, :worried, :fierce}},
    defaults = {expression = :calm}
}
character wren {
    name = "Wren", tag = :wren,
    attributes = {expression = {:calm, :worried, :fierce}},
    defaults = {expression = :calm}
}

-- Procedures: the effects a scene's beats run. A decision is recorded once as a fact; the battle
-- reads `mod` through battle/sync.lua, the endings read `decided`.
procedure decide(?what)
    effect do
        fact decided(what)
        fact mod(what)
    end
end

procedure raise_trust(?hero, ?delta)
    effect do
        local v = quality.get(hero, :trust)
        set quality(hero, :trust, math.max(0, math.min(5, v + delta)))
    end
end

procedure set_flag(?name)
    effect do
        fact flag(name)
    end
end

procedure join_wren()
    effect do
        fact joined(:wren)
        fact flag(:wren_joined)
    end
end

procedure add_bond(?a, ?b)
    effect do
        fact bond(a, b)
        fact flag(:bonded)
    end
end

procedure start_dusk()
    effect do
        set clock(:phase, :dusk)
        fact flag(:started)
    end
end
