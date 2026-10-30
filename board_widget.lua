local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local gwb              = lrequire_common("grid_widget_base")
local GridWidgetBase   = gwb.GridWidgetBase
local drawLine         = gwb.drawLine
local drawDiagonalLine = gwb.drawDiagonalLine

local Solver = lrequire("solver")
local hasBit = Solver.hasBit

local Screen = Device.screen

local C_BG       = Blitbuffer.COLOR_WHITE
local C_GIVEN_BG = Blitbuffer.COLOR_LIGHT_GRAY  -- locked pieces
local C_GRID     = Blitbuffer.COLOR_GRAY_9
local C_INK      = Blitbuffer.COLOR_BLACK
local C_DONE     = Blitbuffer.COLOR_GRAY_9      -- a clue already reached
local C_MARK     = Blitbuffer.COLOR_GRAY_4      -- "no track" cross

-- ---------------------------------------------------------------------------
-- TracksBoardWidget
--
-- The widget is (n+2)×(n+2) units: the n×n grid in the middle, the column
-- clues in the row above it, the row clues in the column to its right, and
-- the entrance (A, left) and exit (B, below) in the remaining margins.
-- ---------------------------------------------------------------------------

local TracksBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function TracksBoardWidget:init()
    local n = self.board and self.board.n or 8
    self.cols = n + 2
    self.rows = n + 2
    self.max_value = 10
    GridWidgetBase.init(self)
    local u = self.cell_w
    self.clue_face  = self:_fitFace("88", u * 0.78, u * 0.60)
    self.label_face = self:_fitFace("B", u * 0.55, u * 0.50)
end

-- The largest cfont size whose rendering of `sample` fits max_w × max_h.
function TracksBoardWidget:_fitFace(sample, max_w, max_h)
    local lo, hi, best = 8, math.max(8, math.floor(max_h * 1.5)), 8
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace("cfont", mid)
        local m    = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return Font:getFace("cfont", best)
end

-- Taps outside the n×n grid (clues, margins) do nothing.
function TracksBoardWidget:onCellTap(row, col)
    local n = self.board.n
    local r, c = row - 1, col - 1
    if r < 1 or r > n or c < 1 or c > n then return end
    if self.onCellAction then self.onCellAction(r, c, false) end
end

function TracksBoardWidget:onCellHold(row, col)
    local n = self.board.n
    local r, c = row - 1, col - 1
    if r < 1 or r > n or c < 1 or c > n then return end
    if self.onCellAction then self.onCellAction(r, c, true) end
end

local function drawText(bb, face, text, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, false)
    local bx = math.floor(cx - m.x / 2)
    local by = math.floor(cy + (m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, bx, by, face, text, true, false, color)
end

function TracksBoardWidget:paintTo(bb, x, y)
    local board = self.board
    if not board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local n    = board.n
    local u    = self.dimen.w / (n + 2)
    local gx   = x + math.floor(u)
    local gy   = y + math.floor(u)
    local gw   = math.floor((n + 1) * u) - math.floor(u)
    local show = board:isShowingSolution()

    local function cellX(c) return x + math.floor(c * u) end      -- left of grid column c
    local function cellY(r) return y + math.floor(r * u) end      -- top of grid row r
    local function midX(c) return x + math.floor((c + 0.5) * u) end
    local function midY(r) return y + math.floor((r + 0.5) * u) end

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Given pieces sit on a grey ground: the player cannot change them.
    for r = 1, n do
        for c = 1, n do
            if board.given[r][c] then
                bb:paintRect(cellX(c), cellY(r), cellX(c + 1) - cellX(c),
                             cellY(r + 1) - cellY(r), C_GIVEN_BG)
            end
        end
    end

    -- Thin inner grid.
    local thin = Size.line.thin or 1
    for i = 1, n - 1 do
        drawLine(bb, cellX(i + 1), gy, thin, gw, C_GRID)
        drawLine(bb, gx, cellY(i + 1), gw, thin, C_GRID)
    end

    -- Rails: a thick bar from the cell centre to each side the piece uses.
    local lw = math.max(3, math.floor(u * 0.20))
    local hw = math.floor(lw / 2)
    for r = 1, n do
        for c = 1, n do
            local m = show and board.solution[r][c] or board:pieceMask(r, c)
            if m ~= 0 then
                local x0, x1 = cellX(c), cellX(c + 1)
                local y0, y1 = cellY(r), cellY(r + 1)
                local cx, cy = midX(c), midY(r)
                bb:paintRect(cx - hw, cy - hw, lw, lw, C_INK)
                if hasBit(m, Solver.N) then bb:paintRect(cx - hw, y0, lw, cy - y0 + hw, C_INK) end
                if hasBit(m, Solver.S) then bb:paintRect(cx - hw, cy - hw, lw, y1 - cy + hw, C_INK) end
                if hasBit(m, Solver.W) then bb:paintRect(x0, cy - hw, cx - x0 + hw, lw, C_INK) end
                if hasBit(m, Solver.E) then bb:paintRect(cx - hw, cy - hw, x1 - cx + hw, lw, C_INK) end
            elseif not show and board.xmark[r][c] then
                local len = math.floor(u * 0.30)
                local t   = math.max(2, math.floor(u * 0.06))
                local cx, cy = midX(c), midY(r)
                drawDiagonalLine(bb, cx - len / 2, cy - len / 2, len, 1, 1, C_MARK, t)
                drawDiagonalLine(bb, cx - len / 2, cy + len / 2 - t, len, 1, -1, C_MARK, t)
            end
        end
    end

    -- Entrance and exit: the rail runs on out of the grid to its letter.
    local stub = math.floor(u * 0.45)
    local ay = midY(board.entry_r)
    bb:paintRect(gx - stub, ay - hw, stub, lw, C_INK)
    drawText(bb, self.label_face, "A", x + math.floor(u * 0.28), ay, C_INK)
    local bx = midX(board.exit_c)
    local by = cellY(n + 1)
    bb:paintRect(bx - hw, by, lw, stub, C_INK)
    drawText(bb, self.label_face, "B", bx, by + math.floor(u * 0.74), C_INK)

    -- Selection: a heavy frame inside the cell.
    if board.selected and not show then
        local s  = board.selected
        local sw = math.max(3, math.floor(u * 0.09))
        local x0, y0 = cellX(s.c), cellY(s.r)
        local w, h = cellX(s.c + 1) - x0, cellY(s.r + 1) - y0
        drawLine(bb, x0, y0, w, sw, C_INK)
        drawLine(bb, x0, y0 + h - sw, w, sw, C_INK)
        drawLine(bb, x0, y0, sw, h, C_INK)
        drawLine(bb, x0 + w - sw, y0, sw, h, C_INK)
    end

    -- Outer frame of the grid.
    local thick = math.max(2, Size.line.thick or 2)
    drawLine(bb, gx, gy, gw, thick, C_INK)
    drawLine(bb, gx, gy + gw - thick, gw, thick, C_INK)
    drawLine(bb, gx, gy, thick, gw, C_INK)
    drawLine(bb, gx + gw - thick, gy, thick, gw, C_INK)

    -- Clues: plain while open, grey once reached, white on black if exceeded.
    local function drawClue(clue, have, cx, cy)
        local text = tostring(clue)
        if show or have < clue then
            drawText(bb, self.clue_face, text, cx, cy, C_INK)
        elseif have == clue then
            drawText(bb, self.clue_face, text, cx, cy, C_DONE)
        else
            local bw = math.floor(u * 0.80)
            bb:paintRect(cx - math.floor(bw / 2), cy - math.floor(bw / 2), bw, bw, C_INK)
            drawText(bb, self.clue_face, text, cx, cy, C_BG)
        end
    end
    for c = 1, n do
        drawClue(board.col_clues[c], board:colCount(c), midX(c), midY(0))
    end
    for r = 1, n do
        drawClue(board.row_clues[r], board:rowCount(r), midX(n + 1), midY(r))
    end
end

return TracksBoardWidget
