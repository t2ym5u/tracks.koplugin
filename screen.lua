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

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = lrequire_common("screen_base")
local MenuHelper        = lrequire_common("menu_helper")
local TracksBoard       = lrequire("board")
local TracksBoardWidget = lrequire("board_widget")
local GenProgress       = lrequire("gen_progress")

local GAME_RULES_EN = _([[
Train Tracks — Rules

Lay a single railway from the entrance A, on the left edge, to the exit B, on the bottom edge.

• Each cell is either empty or holds one piece of track joining two of its sides: straight or curved. The track never branches and never crosses itself.
• The number beside each row and above each column is how many cells of that line the track passes through.
• Grey cells are given pieces; they are part of the answer and cannot be changed.

Controls:
• Tap a cell to select it, then tap a cell next to it to lay the rail between them — or lift it, if it is already there. The cell you tapped becomes the selection, so you can draw a track by tapping its cells one after another.
• Tap the selected cell again to deselect it.
• Hold a cell to mark it with a cross: no track here.

A clue turns grey when its line has exactly enough track, and white on black when it has too much.
]])

local GAME_RULES_FR = [[
Train Tracks — Règles

Posez une seule voie ferrée de l'entrée A, sur le bord gauche, à la sortie B, sur le bord inférieur.

• Chaque case est vide ou contient un morceau de voie qui relie deux de ses côtés : droit ou courbe. La voie ne se divise jamais et ne se croise jamais.
• Le nombre à côté de chaque ligne et au-dessus de chaque colonne indique combien de cases de cette ligne la voie traverse.
• Les cases grises sont des morceaux donnés : ils font partie de la solution et ne peuvent pas être modifiés.

Commandes :
• Touchez une case pour la sélectionner, puis une case voisine pour poser le rail entre elles — ou l'enlever s'il y est déjà. La case touchée devient la sélection : on trace ainsi une voie en touchant ses cases l'une après l'autre.
• Touchez de nouveau la case sélectionnée pour la désélectionner.
• Appui long sur une case pour la marquer d'une croix : pas de voie ici.

Un indice devient gris quand sa ligne a exactement assez de voie, et blanc sur noir quand elle en a trop.
]]

local TracksScreen = ScreenBase:extend{}

function TracksScreen:init()
    local state = self.plugin:loadState()
    self.board  = TracksBoard:new{
        n          = self.plugin:getSetting("grid_n", TracksBoard.DEFAULT_N),
        difficulty = self.plugin:getSetting("difficulty", "easy"),
    }
    if not self.board:load(state) then
        GenProgress.run(function(on_progress) self.board:generate(nil, nil, on_progress) end)
    end
    ScreenBase.init(self)
end

function TracksScreen:serializeState()
    return self.board:serialize()
end

function TracksScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Train Tracks"), function()
        return {
            { text = _("New game"),              callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(),   callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(),   callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:onToggleReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { id = "undo_button", text = _("Undo"), callback = function() self:onUndo() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
        { text = _("Clear"), callback = function() self:onClear() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    self:_updateUndoButton()
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own outer grid line, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = TracksBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold) self:onCellAction(r, c, is_hold) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

local REFUSALS = {
    [TracksBoard.ERR_GIVEN]    = _("That piece is given and cannot change."),
    [TracksBoard.ERR_FULL]     = _("A piece joins only two sides: lift a rail first."),
    [TracksBoard.ERR_ON_TRACK] = _("This cell is certainly part of the track."),
}

function TracksScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() or self.board:isSolved() then return end
    local ok, err
    if is_hold then
        ok, err = self.board:toggleMark(r, c)
    else
        ok, err = self.board:tapCell(r, c)
    end
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if not ok and err and REFUSALS[err] then
        self:updateStatus(REFUSALS[err])
    else
        self:updateStatus()
    end
end

function TracksScreen:onNewGame()
    local n    = self.plugin:getSetting("grid_n", TracksBoard.DEFAULT_N)
    local diff = self.plugin:getSetting("difficulty", "easy")
    self.board = TracksBoard:new{ n = n, difficulty = diff }
    GenProgress.run(function(on_progress) self.board:generate(nil, nil, on_progress) end)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TracksScreen:onUndo()
    if self.board:isShowingSolution() then return end
    if not self.board:undoLast() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
end

function TracksScreen:onClear()
    if self.board:isShowingSolution() then return end
    if self.board:clearAll() then
        self.board.selected = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
    end
    self:updateStatus()
end

function TracksScreen:onHint()
    ScreenBase.onHint(self)
    self:_updateUndoButton()
end

function TracksScreen:onToggleReveal()
    self.board:toggleSolution()
    self.board_widget:refresh()
    self:updateStatus()
end

function TracksScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(TracksBoard.SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", TracksBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function TracksScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

function TracksScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = T(_("Solved! Time: %1"), self.board.timer:format())
    else
        local diff = self.board.difficulty
        status = self:joinStatus(
            T("%1×%1", self.board.n),
            MenuHelper.DIFFICULTY_LABELS[diff] or diff,
            T(_("Track: %1/%2"), self.board:countTrackCells(), self.board:totalTrack()))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

-- Showing the solution can be hidden again, so only solving it ends the round.
function TracksScreen:isRoundOver()
    return self.board:isSolved()
end

function TracksScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function TracksScreen:getDiffButtonText()
    local diff = self.plugin:getSetting("difficulty", "easy")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function TracksScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function TracksScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo() and not self.board:isSolved())
end

return TracksScreen
