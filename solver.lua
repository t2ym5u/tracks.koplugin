-- ---------------------------------------------------------------------------
-- Train Tracks — solver and generator (pure Lua, no KOReader dependency).
--
-- A puzzle is an n×n grid with an entrance on the left edge (row entry_r)
-- and an exit on the bottom edge (column exit_c). The answer is one
-- non-branching track from the entrance to the exit: every cell holds either
-- nothing or a piece joining exactly two of its four sides. The numbers
-- outside the grid count the track cells in each row and column, and a few
-- pieces are given.
--
-- The solver works on edges between orthogonal neighbours (yes / no /
-- unknown) and on cells (track / empty / unknown). It reasons in tiers, which
-- is what the difficulty levels are measured with:
--
--   tier 1  piece rules (a track cell has exactly two exits, an empty cell
--           none) and line counts (a row whose clue is reached is empty
--           elsewhere; one with exactly enough room is full);
--   tier 2  connectivity: an edge joining both ends of the same piece of
--           track would close a loop, and joining the entrance's run to the
--           exit's run is only allowed when that uses up every track cell.
--
-- There is no trial tier: no level ever needs "assume an edge and see if it
-- breaks" (1.1.0; before, Hard needed exactly that). Hard is tier 2 like
-- Medium, with many more tier-2 steps (see solveState()) and fewer givens.
--
-- Every rule is sound — it only ever removes possibilities the real answer
-- does not use — so a grid the solver finishes has exactly one solution.
-- The generator checks that independently anyway with countSolutions().
-- ---------------------------------------------------------------------------

local S = {}

-- Side bits of a piece. Arithmetic, not bit ops: this runs under LuaJIT on
-- the device and under plain Lua in the test runner.
S.N, S.E, S.S, S.W = 1, 2, 4, 8
S.DIRS = {
    { dr = -1, dc =  0, bit = 1, opp = 4 },
    { dr =  0, dc =  1, bit = 2, opp = 8 },
    { dr =  1, dc =  0, bit = 4, opp = 1 },
    { dr =  0, dc = -1, bit = 8, opp = 2 },
}

local function hasBit(m, b)
    return math.floor(m / b) % 2 == 1
end
S.hasBit = hasBit

-- ---------------------------------------------------------------------------
-- Geometry, cached per size: cells are numbered (r-1)*n + c, edges join
-- orthogonal neighbours.
-- ---------------------------------------------------------------------------

local geo_cache = {}

local function geometry(n)
    if geo_cache[n] then return geo_cache[n] end
    local g = { n = n, nc = n * n, ne = 0, ea = {}, eb = {},
                cellE = {}, lines = {} }
    for cell = 1, n * n do g.cellE[cell] = {} end
    local function addEdge(a, b)
        g.ne = g.ne + 1
        local e = g.ne
        g.ea[e], g.eb[e] = a, b
        local la, lb = g.cellE[a], g.cellE[b]
        la[#la + 1] = e
        lb[#lb + 1] = e
    end
    for r = 1, n do
        for c = 1, n - 1 do addEdge((r - 1) * n + c, (r - 1) * n + c + 1) end
    end
    for r = 1, n - 1 do
        for c = 1, n do addEdge((r - 1) * n + c, r * n + c) end
    end
    -- Lines 1..n are rows, n+1..2n columns.
    for r = 1, n do
        local l = {}
        for c = 1, n do l[c] = (r - 1) * n + c end
        g.lines[r] = l
    end
    for c = 1, n do
        local l = {}
        for r = 1, n do l[r] = (r - 1) * n + c end
        g.lines[n + c] = l
    end
    geo_cache[n] = g
    return g
end

-- The edge between two orthogonally adjacent cells.
function S.edgeBetween(n, a, b)
    local g = geometry(n)
    for _, e in ipairs(g.cellE[a]) do
        if g.ea[e] == b or g.eb[e] == b then return e end
    end
end

-- ---------------------------------------------------------------------------
-- Solver state
-- ---------------------------------------------------------------------------

local function find(P, x)
    while P[x] ~= x do
        P[x] = P[P[x]]
        x = P[x]
    end
    return x
end

local function clone(st)
    local E, T, P, Z = {}, {}, {}, {}
    for i = 1, #st.E do E[i] = st.E[i] end
    for i = 1, #st.T do
        T[i] = st.T[i]; P[i] = st.P[i]; Z[i] = st.Z[i]
    end
    return { E = E, T = T, P = P, Z = Z }
end

-- Puzzle context: everything the rules read but never change.
local function context(puz)
    local n = puz.n
    local g = geometry(n)
    local ctx = { g = g, n = n, ext = {}, clue = {}, total = 0 }
    for cell = 1, g.nc do ctx.ext[cell] = 0 end
    ctx.a_cell = (puz.entry_r - 1) * n + 1
    ctx.b_cell = (n - 1) * n + puz.exit_c
    ctx.ext[ctx.a_cell] = ctx.ext[ctx.a_cell] + 1
    ctx.ext[ctx.b_cell] = ctx.ext[ctx.b_cell] + 1
    for r = 1, n do
        ctx.clue[r] = puz.row_clues[r]
        ctx.total = ctx.total + puz.row_clues[r]
    end
    for c = 1, n do ctx.clue[n + c] = puz.col_clues[c] end
    return ctx
end

local function setYes(st, ctx, e)
    local v = st.E[e]
    if v == 1 then return true end
    if v == -1 then return false end
    st.E[e] = 1
    local ra, rb = find(st.P, ctx.g.ea[e]), find(st.P, ctx.g.eb[e])
    -- Joining a run to itself closes a loop: never part of the answer.
    if ra == rb then return false end
    st.P[rb] = ra
    st.Z[ra] = st.Z[ra] + st.Z[rb]
    return true
end

local function setNo(st, e)
    local v = st.E[e]
    if v == -1 then return true end
    if v == 1 then return false end
    st.E[e] = -1
    return true
end

local function setTrack(st, cell, t)
    local v = st.T[cell]
    if v == t then return true end
    if v ~= 0 then return false end
    st.T[cell] = t
    return true
end

-- The side bits of a cell's edges, in cellE order.
local function cellEdgeBits(n, cell, g)
    local bits = {}
    for i, e in ipairs(g.cellE[cell]) do
        local other = (g.ea[e] == cell) and g.eb[e] or g.ea[e]
        local d = other - cell
        if d == 1 then bits[i] = S.E
        elseif d == -1 then bits[i] = S.W
        elseif d == n then bits[i] = S.S
        else bits[i] = S.N end
    end
    return bits
end

local function initState(puz, ctx)
    local g = ctx.g
    local st = { E = {}, T = {}, P = {}, Z = {} }
    for e = 1, g.ne do st.E[e] = 0 end
    for cell = 1, g.nc do
        st.T[cell] = 0; st.P[cell] = cell; st.Z[cell] = 1
    end
    for cell, mask in pairs(puz.given or {}) do
        if not setTrack(st, cell, 1) then return nil end
        local bits = cellEdgeBits(ctx.n, cell, g)
        for i, e in ipairs(g.cellE[cell]) do
            local ok
            if hasBit(mask, bits[i]) then ok = setYes(st, ctx, e) else ok = setNo(st, e) end
            if not ok then return nil end
        end
    end
    return st
end

-- ---------------------------------------------------------------------------
-- Tier 1: piece rules and line counts, to a fixpoint.
-- ---------------------------------------------------------------------------

local function propagate1(st, ctx)
    local g, E, T = ctx.g, st.E, st.T
    local changed = true
    while changed do
        changed = false
        for cell = 1, g.nc do
            local y, u = ctx.ext[cell], 0
            local edges = g.cellE[cell]
            for i = 1, #edges do
                local v = E[edges[i]]
                if v == 1 then y = y + 1 elseif v == 0 then u = u + 1 end
            end
            if y > 2 then return false end
            local t = T[cell]
            if t == -1 then
                if y > 0 then return false end
                if u > 0 then
                    for i = 1, #edges do
                        if E[edges[i]] == 0 then E[edges[i]] = -1 end
                    end
                    changed = true
                end
            elseif y + u < 2 then
                -- Not enough open sides left for a piece.
                if y > 0 then return false end
                T[cell] = -1
                for i = 1, #edges do
                    if E[edges[i]] == 0 then E[edges[i]] = -1 end
                end
                changed = true
            elseif y == 2 then
                if t == 0 then T[cell] = 1; changed = true end
                if u > 0 then
                    for i = 1, #edges do
                        if E[edges[i]] == 0 then E[edges[i]] = -1 end
                    end
                    changed = true
                end
            else
                if y == 1 and t == 0 then T[cell] = 1; t = 1; changed = true end
                if t == 1 and y + u == 2 and u > 0 then
                    for i = 1, #edges do
                        if E[edges[i]] == 0 then
                            if not setYes(st, ctx, edges[i]) then return false end
                        end
                    end
                    changed = true
                end
            end
        end
        for li = 1, #g.lines do
            local line, clue = g.lines[li], ctx.clue[li]
            local ty, tu = 0, 0
            for i = 1, #line do
                local t = T[line[i]]
                if t == 1 then ty = ty + 1 elseif t == 0 then tu = tu + 1 end
            end
            if ty > clue or ty + tu < clue then return false end
            if tu > 0 then
                if ty == clue then
                    for i = 1, #line do
                        if T[line[i]] == 0 then T[line[i]] = -1 end
                    end
                    changed = true
                elseif ty + tu == clue then
                    for i = 1, #line do
                        if T[line[i]] == 0 then T[line[i]] = 1 end
                    end
                    changed = true
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Tier 2: connectivity. One pass; returns ok, changed. first_only: stop at
-- the first edge ruled out (tier-2 steps are counted one by one).
-- ---------------------------------------------------------------------------

local function l2pass(st, ctx, first_only)
    local g, E, P = ctx.g, st.E, st.P
    local changed = false
    local ra, rb = find(P, ctx.a_cell), find(P, ctx.b_cell)
    if ra == rb then
        -- The track is complete: nothing else can be track.
        if st.Z[ra] ~= ctx.total then return false, false end
        for cell = 1, g.nc do
            if st.T[cell] == 0 then st.T[cell] = -1; changed = true end
        end
        for e = 1, g.ne do
            if E[e] == 0 then E[e] = -1; changed = true end
        end
        return true, changed
    end
    for e = 1, g.ne do
        if E[e] == 0 then
            local x, y = find(P, g.ea[e]), find(P, g.eb[e])
            if x == y then
                E[e] = -1; changed = true
                if first_only then return true, true end
            elseif (x == ra and y == rb) or (x == rb and y == ra) then
                if st.Z[x] + st.Z[y] ~= ctx.total then
                    E[e] = -1; changed = true
                    if first_only then return true, true end
                end
            end
        end
    end
    return true, changed
end

local function isComplete(st)
    for e = 1, #st.E do
        if st.E[e] == 0 then return false end
    end
    return true
end

-- A finished state is the answer when the entrance's run reaches the exit
-- and holds every track cell. propagate1 has already checked the pieces and
-- the line counts by the time this is asked.
local function isValidComplete(st, ctx)
    local ra = find(st.P, ctx.a_cell)
    return ra == find(st.P, ctx.b_cell) and st.Z[ra] == ctx.total
end

-- Tiers 1 and 2 to a fixpoint.
local function fullProp(st, ctx)
    while true do
        if not propagate1(st, ctx) then return false end
        local ok, changed = l2pass(st, ctx)
        if not ok then return false end
        if not changed then return true end
    end
end

-- ---------------------------------------------------------------------------
-- Public solver API
-- ---------------------------------------------------------------------------

-- Runs the tiers up to max_tier (at most 2) on `st` (modified in place) to
-- a fixpoint. Returns solved (bool), the highest tier actually needed, and
-- the state. st.t2 counts the tier-2 steps: tier 2 rules out one edge at a
-- time, then tier 1 runs dry again, so each step is something tier 1 could
-- not see at that point. What is deduced does not depend on that order
-- (every rule is sound and only narrows the grid), only the count is new.
local function solveState(st, ctx, max_tier)
    local used = 1
    st.t2 = st.t2 or 0
    while true do
        if not propagate1(st, ctx) then return false, used, st end
        if isComplete(st) then
            return isValidComplete(st, ctx), used, st
        end
        local progressed = false
        if max_tier >= 2 then
            local ok, changed = l2pass(st, ctx, true)
            if not ok then return false, used, st end
            if changed then
                progressed = true; st.t2 = st.t2 + 1
                if used < 2 then used = 2 end
            end
        end
        if not progressed then return false, used, st end
    end
end

-- Solves by deduction only, using tiers up to max_tier (at most 2).
-- Returns solved (bool), the highest tier actually needed, and the state
-- (its t2 field: how many tier-2 steps).
function S.solve(puz, max_tier)
    max_tier = max_tier or 2
    local ctx = context(puz)
    local st = initState(puz, ctx)
    if not st then return false, 0, nil end
    return solveState(st, ctx, max_tier)
end

-- Lays the given piece `mask` into a solver state. Returns false when it
-- contradicts what the state already holds.
local function addGiven(st, ctx, cell, mask)
    if not setTrack(st, cell, 1) then return false end
    local bits = cellEdgeBits(ctx.n, cell, ctx.g)
    for i, e in ipairs(ctx.g.cellE[cell]) do
        local ok
        if hasBit(mask, bits[i]) then ok = setYes(st, ctx, e) else ok = setNo(st, e) end
        if not ok then return false end
    end
    return true
end

-- Exhaustive count, stopping at `limit` (default 2). Independent of the
-- tier bookkeeping: it is how the generator double-checks uniqueness.
-- With `max_nodes`, the search gives up after that many nodes and returns
-- nil instead of a count (the generator then discards the grid: a count is
-- a node budget, never a clock, so every device gives up in the same place).
function S.countSolutions(puz, limit, max_nodes)
    limit = limit or 2
    local ctx = context(puz)
    local st0 = initState(puz, ctx)
    if not st0 then return 0 end
    local g = ctx.g
    local count, nodes = 0, 0
    local function dfs(st)
        nodes = nodes + 1
        if max_nodes and nodes > max_nodes then count = limit; return end
        if not fullProp(st, ctx) then return end
        if isComplete(st) then
            if isValidComplete(st, ctx) then count = count + 1 end
            return
        end
        -- Branch at the loose end with the fewest open sides: exactly one of
        -- them is used, so the branches are disjoint and exhaustive.
        local best, best_u
        for cell = 1, g.nc do
            if st.T[cell] == 1 then
                local y, u = ctx.ext[cell], 0
                for _, e in ipairs(g.cellE[cell]) do
                    local v = st.E[e]
                    if v == 1 then y = y + 1 elseif v == 0 then u = u + 1 end
                end
                if y == 1 and u > 0 and (not best or u < best_u) then
                    best, best_u = cell, u
                end
            end
        end
        if best then
            for _, e in ipairs(g.cellE[best]) do
                if st.E[e] == 0 then
                    local c = clone(st)
                    if setYes(c, ctx, e) then dfs(c) end
                    if count >= limit then return end
                end
            end
            return
        end
        -- No loose end but edges still open: cannot happen while the
        -- entrance's run is unfinished, kept as a safe fallback.
        for e = 1, g.ne do
            if st.E[e] == 0 then
                local c = clone(st)
                if setYes(c, ctx, e) then dfs(c) end
                if count >= limit then return end
                c = clone(st)
                if setNo(c, e) then dfs(c) end
                return
            end
        end
    end
    dfs(st0)
    if max_nodes and nodes > max_nodes then return nil, nodes end
    return count, nodes
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

local function rand(a, b) return math.random(a, b) end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = rand(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- A random simple path from (entry_r, 1) to (n, exit_c), as a list of
-- {r, c}. It starts as an L and is then deformed: "bumps" push a straight
-- pair of cells sideways (two cells longer), "flips" move a corner to the
-- opposite side of its 2×2 square (same length). Both keep the path simple,
-- so no search is needed and every size generates instantly.
function S.randomPath(n)
    local entry_r, exit_c
    repeat
        entry_r, exit_c = rand(1, n), rand(1, n)
    until not (entry_r == n and exit_c == 1)
    local path, used = {}, {}
    local function key(r, c) return (r - 1) * n + c end
    local function push(r, c)
        path[#path + 1] = { r, c }
        used[key(r, c)] = true
    end
    -- The starting route: right along the entrance row to a random column
    -- c1, up or down that column to a random row r2, across to the exit
    -- column, then down to the exit. Starting from an arbitrary route with
    -- three bends rather than the plain L spreads the finished track over
    -- the whole grid instead of letting it grow in the corner the L cuts off.
    -- Going up is only possible when the exit column lies right of c1:
    -- otherwise the final descent would run into the entrance row.
    local c1 = rand(1, n)
    local r2
    if c1 < exit_c then
        r2 = rand(1, n)
    elseif entry_r < n then
        r2 = rand(entry_r + 1, n)
    else
        c1, r2 = exit_c, n
    end
    for c = 1, c1 do push(entry_r, c) end
    local vstep = (r2 >= entry_r) and 1 or -1
    for r = entry_r + vstep, r2, vstep do
        if r ~= entry_r then push(r, c1) end
    end
    local step = (exit_c >= c1) and 1 or -1
    for c = c1 + step, exit_c, step do
        if c ~= c1 then push(r2, c) end
    end
    for r = r2 + 1, n do push(r, exit_c) end

    local function free(r, c)
        return r >= 1 and r <= n and c >= 1 and c <= n and not used[key(r, c)]
    end
    local target = math.floor(n * n * (0.42 + math.random() * 0.16))
    local tries = 0
    while tries < 60 * n * n and (#path < target or tries < 8 * n * n) do
        tries = tries + 1
        if #path < target and math.random() < 0.6 then
            -- Bump: p=path[i], q=path[i+1] move sideways by d.
            local i = rand(1, #path - 1)
            local p, q = path[i], path[i + 1]
            local dr, dc
            if p[1] == q[1] then dr, dc = (math.random() < 0.5) and -1 or 1, 0
            else dr, dc = 0, (math.random() < 0.5) and -1 or 1 end
            local p2r, p2c, q2r, q2c = p[1] + dr, p[2] + dc, q[1] + dr, q[2] + dc
            if free(p2r, p2c) and free(q2r, q2c) then
                table.insert(path, i + 1, { q2r, q2c })
                table.insert(path, i + 1, { p2r, p2c })
                used[key(p2r, p2c)] = true
                used[key(q2r, q2c)] = true
            end
        elseif #path >= 3 then
            -- Flip a corner.
            local i = rand(2, #path - 1)
            local a, b, c = path[i - 1], path[i], path[i + 1]
            if a[1] ~= c[1] and a[2] ~= c[2] then
                local sr, sc = a[1] + c[1] - b[1], a[2] + c[2] - b[2]
                if free(sr, sc) then
                    used[key(b[1], b[2])] = nil
                    path[i] = { sr, sc }
                    used[key(sr, sc)] = true
                end
            end
        end
    end
    return path, entry_r, exit_c
end

-- Turns a path into a puzzle (clues + solution pieces, no givens yet).
function S.puzzleFromPath(n, path, entry_r, exit_c)
    local sol, row_clues, col_clues = {}, {}, {}
    for r = 1, n do
        sol[r] = {}
        row_clues[r] = 0
        for c = 1, n do sol[r][c] = 0 end
    end
    for c = 1, n do col_clues[c] = 0 end
    local function dirBit(from, to)
        local dr, dc = to[1] - from[1], to[2] - from[2]
        for _, d in ipairs(S.DIRS) do
            if d.dr == dr and d.dc == dc then return d.bit end
        end
    end
    for i, p in ipairs(path) do
        local m = 0
        if i == 1 then m = m + S.W else m = m + dirBit(p, path[i - 1]) end
        if i == #path then m = m + S.S else m = m + dirBit(p, path[i + 1]) end
        sol[p[1]][p[2]] = m
        row_clues[p[1]] = row_clues[p[1]] + 1
        col_clues[p[2]] = col_clues[p[2]] + 1
    end
    return {
        n = n, entry_r = entry_r, exit_c = exit_c,
        row_clues = row_clues, col_clues = col_clues,
        solution = sol, given = {},
    }
end

S.TIER = { easy = 1, medium = 2, hard = 2 }

-- What each level asks for (1.1.0):
--   tier            the highest solver tier the grid needs
--   min_t2, max_t2  how many tier-2 steps it needs (see solveState())
-- Hard used to need one-step trials (a third tier), which is guessing. It
-- is now tier 2 like Medium, with clearly more tier-2 steps; Medium gets a
-- ceiling so the two do not overlap.
--   attempts        how many paths to try; past it, the grid closest to
--                   the window found so far is kept
-- Hard windows are met by about 1 path in 7 to 1 in 17; an attempt is
-- cheap (0.3 ms at 6x6 to 1.4 ms at 10x10 on a desktop), so the attempt
-- counts keep the slowest grid near 40 ms (about 1 s on a Kobo).
local MED_MAX    = { [6] = 1, [7] = 1, [8] = 2, [9] = 2, [10] = 3 }
local HARD_MIN   = { [6] = 3, [7] = 3, [8] = 4, [9] = 5, [10] = 5 }
local HARD_TRIES = { [6] = 120, [7] = 100, [8] = 70, [9] = 45, [10] = 28 }
S.LEVELS = {
    easy   = function(n) return { tier = 1, min_t2 = 0, max_t2 = 0, attempts = 12 } end,
    medium = function(n) return { tier = 2, min_t2 = 1, max_t2 = MED_MAX[n] or 3,
                                  attempts = 12 } end,
    hard   = function(n) return { tier = 2, min_t2 = HARD_MIN[n] or 5, max_t2 = math.huge,
                                  attempts = HARD_TRIES[n] or 28 } end,
}

-- How far a solved grid is from what the level asks for (0 = fits).
local function miss(level, tier, t2)
    if tier ~= level.tier then return 1000 + math.abs(tier - level.tier) end
    if t2 < level.min_t2 then return level.min_t2 - t2 end
    if t2 > level.max_t2 then return t2 - level.max_t2 end
    return 0
end

-- The exhaustive cross-check gives up after this many search nodes; the grid
-- is then discarded like one that is not unique, and the next attempt runs.
-- Measured over ~3,000 counts at every size and level: half need a single
-- node, 99 % fewer than 600, but a rare one ran to 24,000 nodes (a second on
-- a desktop, ten on a Kobo). 1,500 turns down 0.4 % of the grids.
S.COUNT_NODE_BUDGET = 1500

-- Generation progress for opts.on_progress(fraction): `inner` (0..1) is how
-- far the current attempt is; each new attempt fills half of what is left of
-- the bar, so it only ever moves forward.
local function report(cb, attempt, inner)
    if cb then cb(1 - 0.5 ^ (attempt - 1) * (1 - inner / 2)) end
end

-- Builds a puzzle that fits the difficulty's level (S.LEVELS) where it can.
-- Returns the puzzle and an info table { tier, t2, givens, attempts, miss }
-- (miss > 0: no attempt fitted, this is the closest one).
--
-- Givens are added (cells the stuck solver could not settle) until the grid
-- is solvable within the tier, then removed again one at a time while it
-- stays so. Adding a given only adds information, so the solve picks up
-- from the stuck state instead of starting over. A medium or hard grid that
-- turns out to need less is regenerated from a new path; after a bounded
-- number of attempts the hardest grid found is kept, so generation always
-- terminates. Every returned grid has passed countSolutions() == 1.
-- opts.on_progress(fraction), if given, is called as generation advances.
-- Everything here is driven by math.random draws and counts only (no
-- clock), so a seed always gives the same grid.
function S.generate(n, difficulty, opts)
    opts = opts or {}
    local level = (S.LEVELS[difficulty] or S.LEVELS.easy)(n)
    if opts.min_t2 then level.min_t2 = opts.min_t2 end
    if opts.max_t2 then level.max_t2 = opts.max_t2 end
    local target = level.tier
    local max_attempts = opts.max_attempts or level.attempts or 12
    local on_progress = opts.on_progress
    local best, best_info
    for attempt = 1, max_attempts do
        report(on_progress, attempt, 0)
        local path, entry_r, exit_c = S.randomPath(n)
        local puz = S.puzzleFromPath(n, path, entry_r, exit_c)
        local sol = puz.solution
        local ctx = context(puz)

        -- Add givens until solvable within the tier. `base` keeps what the
        -- clues alone give: it holds for every set of givens, so the checks
        -- below start from it instead of deducing it all over again.
        local solved, _, st = solveState(initState(puz, ctx), ctx, target)
        local base = clone(st)
        local guard = 0
        while not solved and guard < n * n do
            guard = guard + 1
            local cands = {}
            for _, p in ipairs(path) do
                local cell = (p[1] - 1) * n + p[2]
                if not puz.given[cell] then
                    local open = st.T[cell] ~= 1
                    if not open then
                        for _, e in ipairs(ctx.g.cellE[cell]) do
                            if st.E[e] == 0 then open = true; break end
                        end
                    end
                    if open then cands[#cands + 1] = cell end
                end
            end
            if #cands == 0 then break end
            local cell = cands[rand(1, #cands)]
            local r, c = math.floor((cell - 1) / n) + 1, (cell - 1) % n + 1
            puz.given[cell] = sol[r][c]
            -- Every deduction in `st` holds for any grid with more givens
            -- (the rules are sound), so keep it and lay the new piece on top.
            if not addGiven(st, ctx, cell, sol[r][c]) then st = initState(puz, ctx) end
            solved, _, st = solveState(st, ctx, target)
        end
        report(on_progress, attempt, 0.3)

        if solved then
            -- Remove givens that are not needed.
            local cells = {}
            for cell in pairs(puz.given) do cells[#cells + 1] = cell end
            table.sort(cells)
            shuffle(cells)
            for k, cell in ipairs(cells) do
                local m = puz.given[cell]
                puz.given[cell] = nil
                local t, ok = clone(base), true
                for _, gc in ipairs(cells) do
                    local gm = puz.given[gc]
                    if gm and not addGiven(t, ctx, gc, gm) then ok = false; break end
                end
                if not (ok and solveState(t, ctx, target)) then puz.given[cell] = m end
                report(on_progress, attempt, 0.3 + 0.6 * k / #cells)
            end
            local _, tier, fst = S.solve(puz, target)
            local m = miss(level, tier, fst.t2)
            -- The exhaustive count is the expensive part of a rare grid: only
            -- run it on a grid that would be kept.
            if (not best or m < best_info.miss)
                    and S.countSolutions(puz, 2, S.COUNT_NODE_BUDGET) == 1 then
                local ngiven = 0
                for _ in pairs(puz.given) do ngiven = ngiven + 1 end
                local info = { tier = tier, t2 = fst.t2, givens = ngiven, attempts = attempt, miss = m }
                if m == 0 then
                    report(on_progress, attempt, 1)
                    return puz, info
                end
                best, best_info = puz, info
            end
        end
    end
    if best then return best, best_info end
    -- Unreachable in practice; a fully given grid is always unique.
    local path, entry_r, exit_c = S.randomPath(n)
    local puz = S.puzzleFromPath(n, path, entry_r, exit_c)
    for _, p in ipairs(path) do
        puz.given[(p[1] - 1) * n + p[2]] = puz.solution[p[1]][p[2]]
    end
    return puz, { tier = 1, t2 = 0, givens = #path, attempts = max_attempts, miss = 0 }
end

return S
