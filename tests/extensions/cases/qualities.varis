-- Companion quality constraints and transactional default-world regression.

        assert(require("quality") == quality)
        quality.define(:coins, {initial = 0, minimum = 0, maximum = 100, label = "Coins"})
        quality.define(:optional, {initial = nil, visible = false})
        quality.define(:large, {initial = 9007199254740993, minimum = 9007199254740993})
        local function rejects(f, text)
            local ok, err = pcall(f)
            assert(not ok and string.find(err, text, 1, true), tostring(err))
        end
        rejects(function() quality.define(:bad, {initial = -1, minimum = 0}) end, "below minimum")
        quality.define(:bad, {initial = 1, minimum = 0})
        rejects(function() quality.define(:reversed, {initial = 0, minimum = 10, maximum = 1}) end, "minimum exceeds")
        assert(quality.get(:p, :coins) == nil)
        assert((query {quality(:p, :coins, ?n)})() == nil)
        rejects(function() quality.add(:p, :coins, 1) end, "key is absent")
        quality.initialize(:p, :coins)
        quality.add(:p, :coins, 10)
        quality.initialize(:p, :coins)
        assert(quality.get(:p, :coins) == 10)
        rejects(function() quality.set(:p, :coins, 101) end, "above maximum")
        rejects(function() set quality(:p, :coins, -1) end, "below minimum")
        rejects(function() adjust quality(:p, :coins) by -20 end, "below minimum")
        rejects(function() fact quality(:q, :coins, -1) end, "below minimum")
        assert(quality.get(:p, :coins) == 10 and quality.get(:q, :coins) == nil)
        rejects(function() fact quality(:p, :unknown, 0) end, "unknown quality")
        rejects(function() quality.initialize(:p, "coins") end, "must be a symbol")
        rejects(function() quality.set(:p, :large, 9007199254740992.0) end, "below minimum")
        quality.initialize(:p, :large)
        quality.initialize(:p, :optional)
        assert(quality.get(:p, :optional) == nil)
        assert((query {quality(:p, :optional, nil)})() ~= nil)
        transaction do
            quality.add(:p, :coins, 5)
            assert(quality.get(:p, :coins) == 15)
            transaction do
                quality.add(:p, :coins, 5)
                rollback
            end
            assert(quality.get(:p, :coins) == 15)
            rollback
        end
        assert(quality.get(:p, :coins) == 10)
        local child = logic.world()
        quality.set(:p, :coins, 20, child)
        assert(quality.get(:p, :coins, child) == 20 and quality.get(:p, :coins) == 10)
        logic (child) do
            rejects(function() adjust quality(:p, :coins) by 100 end, "above maximum")
        end
        local empty = logic.emptyworld()
        quality.initialize(:p, :coins, empty)
        assert(quality.get(:p, :coins, empty) == 0)
        storylet earn(?id)
            when {quality(?id, :coins, ?n)}
            title "Earn"
            choice go effect do quality.add(id, :coins, 1) end end
        end
        local session = narrative.new(child)
        session:seed(1)
        local token = session:present().storylets[1].choices[1].token
        session:choose(token)
        assert(quality.get(:p, :coins, child) == 21 and quality.get(:p, :coins) == 10)
        rejects(function() quality.define(:late, {initial = 0}) end, "sealed")
    