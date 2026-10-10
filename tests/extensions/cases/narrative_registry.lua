relation location(entity, room) key(entity)
relation road(2)
fact location(:player, :hall)
fact road(:hall, :garden)
deck :exploration { draw = 3, replacement = false }
narrative.name(:garden, "the Garden")
local registrations = 0
local function priority() registrations = registrations + 1; return 10 end
storylet travel(?from, ?to)
    when {location(:player, ?from), road(?from, ?to)}
    deck :exploration
    priority priority()
    title "Travel to {to}"
    text [[{#if query road(from, to)}Open{{road}}{#else}Closed{/if}]]
    choice proceed
        title "Continue"
        effect do
            set location(:player, to)
        end
    end
end
action arrival(?room)
    when {location(:player, ?room)}
    phase :post
    priority 1
    once_per :turn
    effect do
        set location(:player, room)
    end
end
assert(registrations == 1)
assert(narrative.display(:garden) == "the Garden")
narrative.formatter("nil", function(v) return "[empty]" end)
narrative.formatter(:hall, function(v) return "the Grand Hall" end)
assert(narrative.display(nil) == "[empty]")
assert(narrative.display(:hall) == "the Grand Hall")
reject(function() narrative.formatter(123) end, "narrative formatter must be a function")
reject(function() narrative.formatter(:hall, function() end) end, "duplicate narrative formatter")
assert(narrative.template("Hi {name}{{!}}", {name="Ada"}) == "Hi Ada{!}")
assert(narrative.template("{#if query road(:hall, :garden)}yes{#else}no{/if}", {}) == "yes")
assert(narrative.template("{#if query road(:garden, :hall)}yes{#else}no{/if}", {}) == "no")
local tplVar = "{#variant 2} Sunny {#variant 1} Rainy {/variant}"
assert(narrative.template(tplVar, {}, nil, 0) == " Sunny ")
assert(narrative.template(tplVar, {}, nil, 1) == " Rainy ")
assert(narrative.template(tplVar, {}) == " Sunny ")
reject(function() narrative.template("{#variant 0} x {/variant}", {}) end, "variant weight must be positive and finite")
local version = narrative.seal()
assert(type(version) == "string" and narrative.seal() == version)
reject(function() narrative.name(:x, "X") end, "registry is sealed")
reject(function() narrative.formatter("nil", function() end) end, "registry is sealed")
reject(function()
    storylet later(?from)
        when {location(:player, ?from)}
        title "Later"
        choice do_it effect do end end
    end
end, "registry is sealed")
local sequence = narrative.sequence(nil, :garden, "binary\0string")
assert(sequence.length == 3 and sequence[1] == nil and sequence[2] == :garden)
reject(function() sequence[2] = :hall end, "immutable narrative value")
