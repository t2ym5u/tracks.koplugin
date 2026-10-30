local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local Solver = require("solver")
local Board  = require("board")

local function cellOf(n, r, c) return (r - 1) * n + c end

-- Lays the whole answer through the player's own move API.
local function playSolution(b)
    local n = b.n
    for r = 1, n do
        for c = 1, n do
            local m = b.solution[r][c]
            if Solver.hasBit(m, Solver.E) and not b:_getEdge(r, c, Solver.DIRS[2]) then
                assert(b:toggleEdge(r, c, r, c + 1))
            end
            if Solver.hasBit(m, Solver.S) and r < n and not b:_getEdge(r, c, Solver.DIRS[3]) then
                assert(b:toggleEdge(r, c, r + 1, c))
            end
        end
    end
end

local function newBoard(n, diff, seed)
    math.randomseed(seed or 42)
    local b = Board:new{ n = n or 6, difficulty = diff or "easy" }
    b:generate()
    return b
end

describe("Tracks solver", function()
    it("random paths are simple and run from A to B", function()
        for seed = 1, 40 do
            math.randomseed(seed)
            local n = 6 + seed % 5
            local path, entry_r, exit_c = Solver.randomPath(n)
            assert.are.same({ entry_r, 1 }, path[1])
            assert.are.same({ n, exit_c }, path[#path])
            local seen = {}
            for i, p in ipairs(path) do
                local k = cellOf(n, p[1], p[2])
                assert.is_nil(seen[k], "path revisits a cell")
                seen[k] = true
                if i > 1 then
                    local q = path[i - 1]
                    assert.are.equal(1, math.abs(p[1] - q[1]) + math.abs(p[2] - q[2]))
                end
            end
        end
    end)

    it("a fully given grid has exactly one solution", function()
        math.randomseed(7)
        local path, er, ec = Solver.randomPath(7)
        local puz = Solver.puzzleFromPath(7, path, er, ec)
        for _, p in ipairs(path) do
            puz.given[cellOf(7, p[1], p[2])] = puz.solution[p[1]][p[2]]
        end
        assert.are.equal(1, Solver.countSolutions(puz, 2))
        assert.is_true((Solver.solve(puz, 1)))
    end)

    it("clues alone are usually ambiguous, and the counter says so", function()
        -- A long two-row snake along the bottom with an empty top: swapping
        -- which row holds each bend keeps every count.
        local found = false
        for seed = 1, 30 do
            math.randomseed(seed)
            local path, er, ec = Solver.randomPath(8)
            local puz = Solver.puzzleFromPath(8, path, er, ec)
            if Solver.countSolutions(puz, 2) == 2 then found = true; break end
        end
        assert.is_true(found)
    end)

    it("deduction never contradicts the stored answer (soundness)", function()
        for seed = 1, 30 do
            math.randomseed(seed)
            local n = 6 + seed % 5
            local diff = ({ "easy", "medium", "hard" })[seed % 3 + 1]
            local puz = Solver.generate(n, diff)
            local solved, _, st = Solver.solve(puz, 3)
            assert.is_true(solved)
            -- Every cell's track/empty status matches the answer.
            for r = 1, n do
                for c = 1, n do
                    local want = (puz.solution[r][c] ~= 0) and 1 or -1
                    assert.are.equal(want, st.T[cellOf(n, r, c)])
                end
            end
        end
    end)

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

    it("row and column clues add up to the same total", function()
        math.randomseed(3)
        local puz = Solver.generate(9, "medium")
        local rs, cs = 0, 0
        for i = 1, 9 do rs = rs + puz.row_clues[i]; cs = cs + puz.col_clues[i] end
        assert.are.equal(rs, cs)
    end)
end)

describe("TracksBoard", function()
    it("starts with the given pieces laid and locked", function()
        local b = newBoard(8, "easy", 5)
        local any = false
        for r = 1, 8 do
            for c = 1, 8 do
                if b.given[r][c] then
                    any = true
                    assert.are.equal(b.solution[r][c], b:pieceMask(r, c))
                end
            end
        end
        assert.is_true(any)
    end)

    it("entrance and exit rails are fixed parts of their cells", function()
        local b = newBoard(6, "easy", 2)
        assert.is_true(Solver.hasBit(b:pieceMask(b.entry_r, 1), Solver.W))
        assert.is_true(Solver.hasBit(b:pieceMask(6, b.exit_c), Solver.S))
    end)

    it("tap-select then tap-neighbour lays a rail and moves the selection", function()
        local b = Board:new{ n = 6 }
        b.entry_r, b.exit_c = 1, 6
        assert.is_true(b:tapCell(3, 3))
        assert.are.same({ r = 3, c = 3 }, b.selected)
        assert.is_true(b:tapCell(3, 4))
        assert.is_true(b.hedge[3][3])
        assert.are.same({ r = 3, c = 4 }, b.selected)
        -- Back again lifts it.
        assert.is_true(b:tapCell(3, 3))
        assert.is_false(b.hedge[3][3])
        -- Non-adjacent tap just moves the selection.
        b:tapCell(5, 5)
        assert.are.same({ r = 5, c = 5 }, b.selected)
        b:tapCell(5, 5)
        assert.is_nil(b.selected)
    end)

    it("refuses a third rail on a cell", function()
        local b = Board:new{ n = 6 }
        b.entry_r, b.exit_c = 1, 6
        assert.is_true(b:toggleEdge(3, 3, 3, 4))
        assert.is_true(b:toggleEdge(3, 3, 2, 3))
        local ok, err = b:toggleEdge(3, 3, 4, 3)
        assert.is_false(ok)
        assert.are.equal(Board.ERR_FULL, err)
        -- The entrance cell already has one fixed rail.
        assert.is_true(b:toggleEdge(1, 1, 1, 2))
        ok = b:toggleEdge(1, 1, 2, 1)
        assert.is_false(ok)
    end)

    it("given pieces cannot be changed", function()
        local b = newBoard(8, "easy", 5)
        for r = 1, 8 do
            for c = 1, 8 do
                if b.given[r][c] then
                    local nr = (r < 8) and r + 1 or r - 1
                    local ok, err = b:toggleEdge(r, c, nr, c)
                    assert.is_false(ok)
                    assert.are.equal(Board.ERR_GIVEN, err)
                    ok, err = b:toggleMark(r, c)
                    assert.is_false(ok)
                    return
                end
            end
        end
    end)

    it("a cross mark lifts the cell's rails, and laying a rail removes the mark", function()
        local b = Board:new{ n = 6 }
        b.entry_r, b.exit_c = 1, 6
        b:toggleEdge(3, 3, 3, 4)
        assert.is_true(b:toggleMark(3, 3))
        assert.is_true(b.xmark[3][3])
        assert.is_false(b.hedge[3][3])
        b:toggleEdge(3, 3, 4, 3)
        assert.is_false(b.xmark[3][3])
        -- The entrance cell is certainly track.
        local ok, err = b:toggleMark(1, 1)
        assert.is_false(ok)
        assert.are.equal(Board.ERR_ON_TRACK, err)
    end)

    it("detects the win by the rules", function()
        for seed = 1, 6 do
            local b = newBoard(6 + seed % 3, "medium", seed)
            assert.is_false(b:isSolved())
            playSolution(b)
            assert.is_true(b:isSolved())
            assert.is_false(b.timer:isRunning())
        end
    end)

    it("is not won with a correct-count but broken track", function()
        local b = newBoard(7, "easy", 9)
        playSolution(b)
        assert.is_true(b:isSolved())
        b.solved = false
        -- Lift one non-given rail: the line counts may still hold but the
        -- run from A no longer reaches B.
        for r = 1, 7 do
            for c = 1, 6 do
                if b.hedge[r][c] and not b.given[r][c] and not b.given[r][c + 1] then
                    b.hedge[r][c] = false
                    assert.is_false(b:checkWin())
                    return
                end
            end
        end
    end)

    it("undo reverts moves, marks and clears", function()
        local b = Board:new{ n = 6 }
        b.entry_r, b.exit_c = 1, 6
        b:toggleEdge(2, 2, 2, 3)
        b:toggleMark(4, 4)
        b:clearAll()
        assert.is_false(b.hedge[2][2])
        assert.is_true(b:undoLast())
        assert.is_true(b.hedge[2][2])
        assert.is_true(b.xmark[4][4])
        assert.is_true(b:undoLast())
        assert.is_false(b.xmark[4][4])
        assert.is_true(b:undoLast())
        assert.is_false(b.hedge[2][2])
        assert.is_false(b:undoLast())
    end)

    it("serialize / load round trip", function()
        local b = newBoard(8, "hard", 11)
        b:toggleMark(1, 8)
        local r, c = b.entry_r, 1
        if c < 8 and not b.given[r][2] and b:degree(r, 1) < 2 then b:toggleEdge(r, 1, r, 2) end
        local data = b:serialize()
        local b2 = Board:new()
        assert.is_true(b2:load(data))
        assert.are.equal(b.n, b2.n)
        assert.are.equal(b.entry_r, b2.entry_r)
        assert.are.equal(b.exit_c, b2.exit_c)
        assert.are.same(b.solution, b2.solution)
        assert.are.same(b.row_clues, b2.row_clues)
        for rr = 1, 8 do
            for cc = 1, 8 do
                assert.are.equal(b:pieceMask(rr, cc), b2:pieceMask(rr, cc))
                assert.are.equal(b.xmark[rr][cc], b2.xmark[rr][cc])
            end
        end
        assert.is_true(b2:canUndo())
        assert.is_false(Board:new():load(nil))
        assert.is_false(Board:new():load({ n = 6 }))
    end)

    it("saving does not stop the clock", function()
        local b = newBoard(6, "easy", 1)
        assert.is_true(b.timer:isRunning())
        b:serialize()
        assert.is_true(b.timer:isRunning())
    end)
end)

describe("Tracks hint", function()
    it("successive hints finish the grid", function()
        for seed = 1, 5 do
            local b = newBoard(6 + seed, "hard", seed)
            local guard = 0
            while not b:isSolved() and guard < 200 do
                guard = guard + 1
                local step = b:findHint()
                assert.is_not_nil(step)
                assert.are.equal("fill", step.kind)
                assert.is_true(b:applyHint(step))
            end
            assert.is_true(b:isSolved())
        end
    end)

    it("reports a wrong rail before filling anything, and clears it", function()
        local b = newBoard(8, "medium", 4)
        -- Find two adjacent free cells the answer does not join.
        for r = 1, 8 do
            for c = 1, 7 do
                if not Solver.hasBit(b.solution[r][c], Solver.E) and not b.given[r][c]
                   and not b.given[r][c + 1] and b:degree(r, c) < 2 and b:degree(r, c + 1) < 2 then
                    assert.is_true(b:toggleEdge(r, c, r, c + 1))
                    local step = b:findHint()
                    assert.are.equal("mistake", step.kind)
                    assert.is_true(b:applyHint(step))
                    assert.is_false(b.hedge[r][c])
                    return
                end
            end
        end
        error("no candidate edge found")
    end)

    it("a correct partial piece is completed, not called a mistake", function()
        local b = Board:new{ n = 6 }
        b.entry_r, b.exit_c = 1, 6
        for r = 1, 6 do for c = 1, 6 do b.solution[r][c] = 0 end end
        -- Answer: along row 1 then down column 6.
        for c = 1, 6 do b.solution[1][c] = Solver.E + Solver.W end
        b.solution[1][6] = Solver.W + Solver.S
        for r = 2, 6 do b.solution[r][6] = Solver.N + Solver.S end
        b:toggleEdge(1, 2, 1, 3)
        local step = b:findHint()
        assert.are.equal("fill", step.kind)
    end)

    it("a cross on a track cell is a mistake", function()
        local b = newBoard(7, "easy", 8)
        for r = 1, 7 do
            for c = 1, 7 do
                if b.solution[r][c] ~= 0 and not b.given[r][c] and b:extMask(r, c) == 0
                   and b:pieceMask(r, c) == 0 then
                    assert.is_true(b:toggleMark(r, c))
                    local step = b:findHint()
                    assert.are.equal("mistake", step.kind)
                    assert.are.equal(r, step.r)
                    assert.are.equal(c, step.c)
                    b:applyHint(step)
                    assert.is_false(b.xmark[r][c])
                    return
                end
            end
        end
    end)
end)
