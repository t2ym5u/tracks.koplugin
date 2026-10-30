-- ---------------------------------------------------------------------------
-- TracksBoard — game state for Train Tracks.
--
-- The player's track is stored as edges between orthogonal neighbours:
-- hedge[r][c] joins (r,c) to (r,c+1), vedge[r][c] joins (r,c) to (r+1,c).
-- A cell's piece is read back from its edges (pieceMask), so two neighbours
-- can never disagree about the rail between them. The entrance and exit
-- rails that leave the grid are fixed and always drawn.
--
-- Given pieces lock every edge around them: their rails cannot be removed
-- and no rail can be added to a side they leave closed.
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack = require("undo_stack")
local Timer     = require("timer")
local Hint      = require("hint")

local Solver = lrequire("solver")

local hasBit = Solver.hasBit
local N, E, S, W = Solver.N, Solver.E, Solver.S, Solver.W

local TracksBoard = {}
TracksBoard.__index = TracksBoard

TracksBoard.SIZES     = { 6, 7, 8, 9, 10 }
TracksBoard.DEFAULT_N = 8

-- Refusal reasons, as ids: the screen words them. A board that formats UI
-- strings drags KOReader's gettext into every headless test touching it.
TracksBoard.ERR_GIVEN     = "given"
TracksBoard.ERR_FULL      = "full"
TracksBoard.ERR_ON_TRACK  = "on_track"
TracksBoard.ERR_SOLVED    = "solved"

function TracksBoard:new(opts)
    opts = opts or {}
    local o = setmetatable({
        n          = opts.n or TracksBoard.DEFAULT_N,
        difficulty = opts.difficulty or "easy",
        undo       = UndoStack:new(),
        timer      = Timer:new(),
    }, self)
    o:_reset()
    return o
end

-- Empty structures for the current size; generate()/load() fill them.
function TracksBoard:_reset()
    local n = self.n
    self.entry_r, self.exit_c = 1, n
    self.row_clues, self.col_clues = {}, {}
    self.solution, self.given = {}, {}
    self.hedge, self.vedge, self.xmark = {}, {}, {}
    for r = 1, n do
        self.row_clues[r], self.col_clues[r] = 0, 0
        self.solution[r], self.given[r] = {}, {}
        self.hedge[r], self.vedge[r], self.xmark[r] = {}, {}, {}
        for c = 1, n do
            self.solution[r][c] = 0
            self.given[r][c] = false
            self.hedge[r][c] = false
            self.vedge[r][c] = false
            self.xmark[r][c] = false
        end
    end
    self.selected = nil
    self.solved = false
    self.showing_solution = false
    self.hints_used = 0
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

-- on_progress(fraction), optional, is called as generation advances (the
-- screen drives a progress bar with it).
function TracksBoard:generate(n, difficulty, on_progress)
    self.n = n or self.n
    self.difficulty = difficulty or self.difficulty
    self:_reset()
    local puz, info = Solver.generate(self.n, self.difficulty, { on_progress = on_progress })
    self.gen_info = info
    self.entry_r, self.exit_c = puz.entry_r, puz.exit_c
    self.row_clues, self.col_clues = puz.row_clues, puz.col_clues
    self.solution = puz.solution
    for cell, mask in pairs(puz.given) do
        local r, c = math.floor((cell - 1) / self.n) + 1, (cell - 1) % self.n + 1
        self.given[r][c] = true
        -- Lay the given rails; their edges are locked from now on.
        for _, d in ipairs(Solver.DIRS) do
            if hasBit(mask, d.bit) then self:_setEdgeRaw(r, c, d, true) end
        end
    end
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- The solver's view of the grid, for tests and the uniqueness check.
function TracksBoard:toPuzzle()
    local given = {}
    for r = 1, self.n do
        for c = 1, self.n do
            if self.given[r][c] then given[(r - 1) * self.n + c] = self.solution[r][c] end
        end
    end
    return { n = self.n, entry_r = self.entry_r, exit_c = self.exit_c,
             row_clues = self.row_clues, col_clues = self.col_clues, given = given }
end

-- ---------------------------------------------------------------------------
-- Edges and pieces
-- ---------------------------------------------------------------------------

local function inGrid(n, r, c) return r >= 1 and r <= n and c >= 1 and c <= n end

local function dirTo(r1, c1, r2, c2)
    for _, d in ipairs(Solver.DIRS) do
        if r1 + d.dr == r2 and c1 + d.dc == c2 then return d end
    end
end

-- The fixed rail leaving the grid at the entrance / exit, if this cell has one.
function TracksBoard:extMask(r, c)
    local m = 0
    if c == 1 and r == self.entry_r then m = m + W end
    if r == self.n and c == self.exit_c then m = m + S end
    return m
end

function TracksBoard:_getEdge(r, c, d)
    local r2, c2 = r + d.dr, c + d.dc
    if not inGrid(self.n, r2, c2) then return false end
    if d.dc ~= 0 then
        return self.hedge[r][math.min(c, c2)]
    end
    return self.vedge[math.min(r, r2)][c]
end

function TracksBoard:_setEdgeRaw(r, c, d, v)
    local r2, c2 = r + d.dr, c + d.dc
    if not inGrid(self.n, r2, c2) then return end
    if d.dc ~= 0 then
        self.hedge[r][math.min(c, c2)] = v
    else
        self.vedge[math.min(r, r2)][c] = v
    end
end

-- The player's piece in a cell: its side bits, fixed entrance/exit included.
function TracksBoard:pieceMask(r, c)
    local m = self:extMask(r, c)
    for _, d in ipairs(Solver.DIRS) do
        if self:_getEdge(r, c, d) then m = m + d.bit end
    end
    return m
end

function TracksBoard:degree(r, c)
    local m, k = self:pieceMask(r, c), 0
    for _, d in ipairs(Solver.DIRS) do
        if hasBit(m, d.bit) then k = k + 1 end
    end
    return k
end

function TracksBoard:isEdgeLocked(r, c, d)
    local r2, c2 = r + d.dr, c + d.dc
    return self.given[r][c] or (inGrid(self.n, r2, c2) and self.given[r2][c2])
end

-- Toggles the rail between two orthogonal neighbours. Returns ok, err.
function TracksBoard:toggleEdge(r1, c1, r2, c2)
    if self.solved then return false, TracksBoard.ERR_SOLVED end
    local d = dirTo(r1, c1, r2, c2)
    if not d or not inGrid(self.n, r2, c2) then return false end
    if self:isEdgeLocked(r1, c1, d) then return false, TracksBoard.ERR_GIVEN end
    local old = self:_getEdge(r1, c1, d)
    if not old and (self:degree(r1, c1) >= 2 or self:degree(r2, c2) >= 2) then
        -- A piece joins exactly two sides; a third rail would branch.
        return false, TracksBoard.ERR_FULL
    end
    local move = { edges = { { r = r1, c = c1, d = d.bit, old = old, new = not old } }, x = {} }
    -- A rail through a cell overrides a "no track" mark there.
    for _, p in ipairs({ { r1, c1 }, { r2, c2 } }) do
        if not old and self.xmark[p[1]][p[2]] then
            move.x[#move.x + 1] = { r = p[1], c = p[2], old = true, new = false }
            self.xmark[p[1]][p[2]] = false
        end
    end
    self:_setEdgeRaw(r1, c1, d, not old)
    self.undo:push(move)
    self:_afterMove()
    return true
end

local function dirByBit(bit)
    for _, d in ipairs(Solver.DIRS) do
        if d.bit == bit then return d end
    end
end

-- Toggles the "no track here" mark. Returns ok, err.
function TracksBoard:toggleMark(r, c)
    if self.solved then return false, TracksBoard.ERR_SOLVED end
    if self.given[r][c] then return false, TracksBoard.ERR_GIVEN end
    if self:extMask(r, c) ~= 0 then return false, TracksBoard.ERR_ON_TRACK end
    local new = not self.xmark[r][c]
    local move = { edges = {}, x = { { r = r, c = c, old = not new, new = new } } }
    if new then
        -- Marking a cell empty takes its rails out with it, unless one of
        -- them belongs to a given piece: then the cell is certainly track.
        for _, d in ipairs(Solver.DIRS) do
            if self:_getEdge(r, c, d) and self:isEdgeLocked(r, c, d) then
                return false, TracksBoard.ERR_ON_TRACK
            end
        end
        for _, d in ipairs(Solver.DIRS) do
            if self:_getEdge(r, c, d) then
                move.edges[#move.edges + 1] = { r = r, c = c, d = d.bit, old = true, new = false }
                self:_setEdgeRaw(r, c, d, false)
            end
        end
    end
    self.xmark[r][c] = new
    self.undo:push(move)
    self:_afterMove()
    return true
end

-- Sets a cell's piece to `mask` in one undoable step, leaving locked rails
-- alone. Used by the Hint button (fill) and by clearCell (mask 0).
function TracksBoard:setPiece(r, c, mask)
    if self.solved or self.given[r][c] then return false end
    local move = { edges = {}, x = {} }
    for _, d in ipairs(Solver.DIRS) do
        local r2, c2 = r + d.dr, c + d.dc
        if inGrid(self.n, r2, c2) and not self:isEdgeLocked(r, c, d) then
            local want = hasBit(mask, d.bit)
            local old = self:_getEdge(r, c, d)
            if old ~= want then
                move.edges[#move.edges + 1] = { r = r, c = c, d = d.bit, old = old, new = want }
                self:_setEdgeRaw(r, c, d, want)
                if want and self.xmark[r2][c2] then
                    move.x[#move.x + 1] = { r = r2, c = c2, old = true, new = false }
                    self.xmark[r2][c2] = false
                end
            end
        end
    end
    if self.xmark[r][c] then
        move.x[#move.x + 1] = { r = r, c = c, old = true, new = false }
        self.xmark[r][c] = false
    end
    if #move.edges == 0 and #move.x == 0 then return true end
    self.undo:push(move)
    self:_afterMove()
    return true
end

-- Removes every rail and mark the player laid (givens stay), undoably.
function TracksBoard:clearAll()
    if self.solved then return false end
    local move = { edges = {}, x = {} }
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            for _, d in ipairs({ dirByBit(E), dirByBit(S) }) do
                if self:_getEdge(r, c, d) and not self:isEdgeLocked(r, c, d) then
                    move.edges[#move.edges + 1] = { r = r, c = c, d = d.bit, old = true, new = false }
                    self:_setEdgeRaw(r, c, d, false)
                end
            end
            if self.xmark[r][c] then
                move.x[#move.x + 1] = { r = r, c = c, old = true, new = false }
                self.xmark[r][c] = false
            end
        end
    end
    if #move.edges == 0 and #move.x == 0 then return false end
    self.undo:push(move)
    self:_afterMove()
    return true
end

function TracksBoard:canUndo()
    return self.undo:canUndo()
end

function TracksBoard:undoLast()
    local move = self.undo:pop()
    if not move then return false end
    for i = #move.edges, 1, -1 do
        local e = move.edges[i]
        self:_setEdgeRaw(e.r, e.c, dirByBit(e.d), e.old)
    end
    for i = #move.x, 1, -1 do
        local x = move.x[i]
        self.xmark[x.r][x.c] = x.old
    end
    self.solved = false
    self.timer:start()
    return true
end

function TracksBoard:_afterMove()
    self.solved = self:checkWin()
    if self.solved then
        self.selected = nil
        self.timer:stop()
    end
end

-- ---------------------------------------------------------------------------
-- Tap handling: tap a cell to select it, tap an orthogonal neighbour to lay
-- (or lift) the rail between them; the neighbour becomes the selection, so a
-- track is drawn by tapping its cells one after another.
-- Returns ok, err.
-- ---------------------------------------------------------------------------

function TracksBoard:tapCell(r, c)
    if self.solved then return false, TracksBoard.ERR_SOLVED end
    local sel = self.selected
    if sel and sel.r == r and sel.c == c then
        self.selected = nil
        return true
    end
    if sel and dirTo(sel.r, sel.c, r, c) then
        local ok, err = self:toggleEdge(sel.r, sel.c, r, c)
        if ok and not self.solved then self.selected = { r = r, c = c } end
        return ok, err
    end
    self.selected = { r = r, c = c }
    return true
end

function TracksBoard:setSelection(r, c)
    self.selected = { r = r, c = c }
end

-- ---------------------------------------------------------------------------
-- Counts and win check
-- ---------------------------------------------------------------------------

-- Track cells the player has in a row / column: any cell with a rail.
function TracksBoard:rowCount(r)
    local k = 0
    for c = 1, self.n do
        if self:pieceMask(r, c) ~= 0 then k = k + 1 end
    end
    return k
end

function TracksBoard:colCount(c)
    local k = 0
    for r = 1, self.n do
        if self:pieceMask(r, c) ~= 0 then k = k + 1 end
    end
    return k
end

function TracksBoard:totalTrack()
    local t = 0
    for r = 1, self.n do t = t + self.row_clues[r] end
    return t
end

function TracksBoard:countTrackCells()
    local k = 0
    for r = 1, self.n do k = k + self:rowCount(r) end
    return k
end

-- By the rules, not by comparison with the stored answer: every piece joins
-- exactly two sides, one run leads from the entrance to the exit and holds
-- every track cell, and the line counts match.
function TracksBoard:checkWin()
    local n = self.n
    local cells = 0
    for r = 1, n do
        for c = 1, n do
            local deg = self:degree(r, c)
            if deg == 1 or deg > 2 then return false end
            if deg == 2 then cells = cells + 1 end
        end
        if self:rowCount(r) ~= self.row_clues[r] then return false end
    end
    for c = 1, n do
        if self:colCount(c) ~= self.col_clues[c] then return false end
    end
    -- Walk from the entrance.
    local r, c, from = self.entry_r, 1, W
    local walked = 0
    while true do
        walked = walked + 1
        if walked > n * n then return false end
        local m = self:pieceMask(r, c)
        local nextd
        for _, d in ipairs(Solver.DIRS) do
            if d.bit ~= from and hasBit(m, d.bit) then nextd = d; break end
        end
        if not nextd then return false end
        if r == n and c == self.exit_c and nextd.bit == S then break end
        r, c, from = r + nextd.dr, c + nextd.dc, nextd.opp
        if not inGrid(n, r, c) then return false end
    end
    return walked == cells
end

function TracksBoard:isSolved()
    return self.solved
end

-- ---------------------------------------------------------------------------
-- Solution display
-- ---------------------------------------------------------------------------

function TracksBoard:toggleSolution()
    self.showing_solution = not self.showing_solution
end

function TracksBoard:isShowingSolution()
    return self.showing_solution
end

-- ---------------------------------------------------------------------------
-- Hint. The unit is a cell's piece. A piece that is still partly drawn but
-- only uses rails of the answer is "not done yet", not a mistake, so it is
-- reported as empty and the hint completes it; any rail the answer does not
-- have, or a "no track" mark on a track cell, is a mistake.
-- ---------------------------------------------------------------------------

local function hintUser(b, r, c)
    local sol, m = b.solution[r][c], b:pieceMask(r, c)
    for _, d in ipairs(Solver.DIRS) do
        if hasBit(m, d.bit) and not hasBit(sol, d.bit) then return m end
    end
    if b.xmark[r][c] and sol ~= 0 then return -1 end
    if m == sol then return sol end
    return 0
end

Hint.install(TracksBoard, {
    isEmpty     = function(v) return v == nil or v == 0 end,
    getUser     = hintUser,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b.given[r][c] end,
    setCell     = function(b, r, c, v) return b:setPiece(r, c, v) end,
    clearCell   = function(b, r, c) return b:setPiece(r, c, 0) end,
})

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function TracksBoard:serialize()
    -- Timer:serialize() stops the clock to bank the elapsed time; the game
    -- is saved after every move, so restart it or it would freeze at the
    -- first save.
    local timer = self.timer:serialize()
    if timer.was_running then self.timer:start() end
    return {
        n          = self.n,
        difficulty = self.difficulty,
        entry_r    = self.entry_r,
        exit_c     = self.exit_c,
        row_clues  = self.row_clues,
        col_clues  = self.col_clues,
        solution   = self.solution,
        given      = self.given,
        hedge      = self.hedge,
        vedge      = self.vedge,
        xmark      = self.xmark,
        solved     = self.solved,
        hints_used = self.hints_used,
        timer      = timer,
        undo       = self.undo:serialize(),
    }
end

function TracksBoard:load(data)
    if type(data) ~= "table" or type(data.n) ~= "number"
       or type(data.solution) ~= "table" or type(data.hedge) ~= "table" then
        return false
    end
    self.n = data.n
    self:_reset()
    self.difficulty = data.difficulty or "easy"
    self.entry_r    = data.entry_r or 1
    self.exit_c     = data.exit_c or self.n
    for _, key in ipairs({ "row_clues", "col_clues", "solution", "given",
                           "hedge", "vedge", "xmark" }) do
        if type(data[key]) == "table" then self[key] = data[key] end
    end
    self.solved     = data.solved and true or false
    self.hints_used = data.hints_used or 0
    self.timer:load(data.timer)
    self.undo:load(data.undo)
    return true
end

return TracksBoard
