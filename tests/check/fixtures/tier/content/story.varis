relation ready(0)
local counter = 0
storylet a()
    when { ready() }
    title "A"
    choice go
        title "Go"
        effect do
            local co = coroutine.create(function() end)
            narrative.defer(function() print("fine") end)
            narrative.defer(function() counter = counter + 1 end)
            setmetatable({}, {})
        end
    end
end
local function helper() return 1 end
