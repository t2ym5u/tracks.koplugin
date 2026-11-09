-- Difficulty guarantees for Tracks: every size x level builds a unique
-- puzzle quickly, the game's solver finishes it at the level's tier with no
-- trial, Easy needs tier 1 only, Easy < Medium < Hard in tier-2 steps with
-- no overlap between Medium and Hard, and a seed gives the same puzzle
-- without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local Solver = require("solver")
local Board  = require("board")

-- Runs fn with os.clock unusable and os.time allowed only to the game timer.
local function withoutClock(fn)
    local clock, time = os.clock, os.time
    os.clock = function() error("generation read os.clock") end
    os.time = function(...)
        local src = debug.getinfo(2, "S").source
        if not src:find("timer%.lua$") then error("generation read os.time from " .. src) end
        return time(...)
    end
    local ok, err = pcall(fn)
    os.clock, os.time = clock, time
    if not ok then error(err, 0) end
end

-- Everything that defines the puzzle, as a string.
local function fingerprint(b)
    local t = { b.n, b.entry_r, b.exit_c }
    for r = 1, b.n do
        t[#t + 1] = b.row_clues[r] .. "/" .. b.col_clues[r]
        for c = 1, b.n do
            t[#t + 1] = b.solution[r][c] .. (b.given[r][c] and "g" or "")
        end
    end
    return table.concat(t, ",")
end

local function generate(n, diff, seed, on_progress)
    math.randomseed(seed)
    local b = Board:new{ n = n, difficulty = diff }
    withoutClock(function() b:generate(nil, nil, on_progress) end)
    return b
end

describe("Tracks difficulty", function()
    it("generates unique puzzles at the requested tier, every size and level", function()
        for _, n in ipairs({ 6, 8, 10 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for seed = 1, 6 do
                    math.randomseed(seed * 31 + n)
                    local puz, info = Solver.generate(n, diff)
                    assert.are.equal(1, Solver.countSolutions(puz, 2))
                    assert.are.equal(Solver.TIER[diff], info.tier)
                    -- Solvable within the tier, and not below it.
                    assert.is_true((Solver.solve(puz, info.tier)))
                    if info.tier > 1 then
                        assert.is_false((Solver.solve(puz, info.tier - 1)))
                    end
                end
            end
        end
    end)

    -- 1.1.0: Hard used to need one-step trials ("assume an edge, see it
    -- break"), which is guessing. No level may need more than tier 2 now.
    it("no level needs trial and error (30 seeds per size and level)", function()
        for _, n in ipairs({ 6, 7, 8, 9, 10 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for seed = 1, 30 do
                    math.randomseed(seed * 7919 + n)
                    local puz, info = Solver.generate(n, diff)
                    assert.is_true(info.tier <= 2)
                    local ok, _, st = Solver.solve(puz, 2)
                    assert.is_true(ok, ("%dx%d %s seed %d"):format(n, n, diff, seed))
                    assert.are.equal(info.t2, st.t2)
                end
            end
        end
    end)

    -- 1.1.0: Hard is tier 2 like Medium, with clearly more tier-2 steps,
    -- and Medium has a ceiling, so the levels do not overlap.
    it("Easy < Medium < Hard in tier-2 steps, every size", function()
        for _, n in ipairs({ 6, 7, 8, 9, 10 }) do
            local sum = { easy = 0, medium = 0, hard = 0 }
            local med_max, hard_min, fit = 0, math.huge, 0
            local K = 20
            for seed = 1, K do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    math.randomseed(seed * 31 + n)
                    local _, info = Solver.generate(n, diff)
                    sum[diff] = sum[diff] + info.t2
                    if info.miss == 0 then fit = fit + 1 end
                    if diff == "medium" then med_max = math.max(med_max, info.t2) end
                    if diff == "hard" then hard_min = math.min(hard_min, info.t2) end
                end
            end
            assert.are.equal(0, sum.easy)
            assert.is_true(sum.medium >= K)
            assert.is_true(sum.hard >= 2 * sum.medium, ("%d: %d vs %d"):format(n, sum.hard, sum.medium))
            assert.is_true(hard_min > med_max, ("%d: hard %d, medium %d"):format(n, hard_min, med_max))
            assert.is_true(fit >= 3 * K - 2)
        end
    end)

    it("builds 10x10 Hard within a generous bound", function()
        local worst = 0
        for seed = 1, 10 do
            math.randomseed(seed * 101)
            local t0 = os.clock()
            Solver.generate(10, "hard")
            worst = math.max(worst, os.clock() - t0)
        end
        -- about 25 ms at worst on a desktop under LuaJIT
        assert.is_true(worst < 1.0, ("took %.2f s"):format(worst))
    end)

    it("builds the same puzzle from the same seed, without reading the clock", function()
        for _, case in ipairs({ { 6, "easy" }, { 8, "medium" }, { 10, "hard" } }) do
            local a = fingerprint(generate(case[1], case[2], 2024))
            local b = fingerprint(generate(case[1], case[2], 2024, function() end))
            assert.are.equal(a, b)
            assert.are_not.equal(a, fingerprint(generate(case[1], case[2], 2025)))
        end
    end)

    it("every size and level builds within a generous time bound", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local worst = 0
                for seed = 1, 5 do
                    math.randomseed(seed * 211 + n)
                    local t0 = os.clock()
                    Solver.generate(n, diff)
                    worst = math.max(worst, os.clock() - t0)
                end
                assert.is_true(worst < 1.5, ("%dx%d %s took %.2f s"):format(n, n, diff, worst))
            end
        end
    end)
end)
