--------------------------------------------------------------------------------
-- Timeline - the whole run on one line, and where you are on it
--
-- The chat line is the record; this is the instrument. It answers "how are we
-- doing right now" continuously, so the group sees a gap widening rather than
-- learning about it once the boss is already down.
--
-- ## Why a line and not a bar
--
-- The bar this replaces raced ONE boss at a time: a track that meant a different
-- thing every few minutes, and that threw away everything already banked the
-- moment a boss died. You could see the next gap and nothing else - not the shape
-- of the run, not how far the route still had to go, not whether the twenty
-- seconds lost at the first boss had been given back since.
--
-- So: one axis for the whole key, and it does not move.
--
--   0                                                     the last boss's pace
--   |----[#]--o------[##]--#--------------[###]----------------[##]-----|
--        boss 1        boss 2, killed     you        boss 3      boss 4
--        killed        behind
--
--   * the RAIL is the run, from the start to the last boss's published pace
--   * a RANGE block per boss - the middle half of that boss's pool
--   * a PACE node per boss - the median, the thing being raced
--   * once a boss is down, a MARK where it actually died, with a LINK back to
--     the pace node. That link's LENGTH is the delta, drawn to scale
--   * the MARKER - a dot travelling the rail, which is you
--
-- Everything on the axis is the same quantity: real elapsed seconds from
-- `CHALLENGE_MODE_START`. That is what the published pool was built from, and it
-- is why the dungeon's own time limit is NOT drawn here even though it is the
-- obvious finish line: the keystone timer carries the death penalty and the
-- published splits carry none, so a deadline drawn on this axis would sit five
-- seconds per death away from the truth, and nothing about it would look wrong.
-- The last boss's pace is the honest end of a run that can be compared at all -
-- the same reason Pace sums up at the last boss rather than at the portal.
--
-- ## The scale is fixed
--
-- Set once from the pool, with a little headroom past the slow quarter, and it
-- does not grow to fit an overrun. A track that rescales keeps the marker in the
-- same place while the numbers get worse, which is the opposite of what an
-- instrument is for. Past the right edge it saturates and the text carries the
-- number.
--
-- ## Colour is never the only signal
--
-- Ahead is the theme accent and behind is its danger red - and the delta is also
-- written out in words, because a display that only says "bad" in red says
-- nothing at all to a reader who cannot see the difference. The geometry says it
-- a third time: a mark to the RIGHT of its pace node is late, whatever colour
-- anybody's monitor makes of it.
--
-- There is no green here on purpose: the Peavers palette has none, and inventing
-- one for this addon would be the one surface in the suite that does.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons
local Theme = PeaversCommons.Theme
local C = Theme and Theme.Colors or {}

local Timeline = {}
PS.Timeline = Timeline

local frame, track, rail, trail, marker, playhead, finishLine
local panelBg, trackBg
local headerText, deltaText, finishText
local nodes = {}
local lastUpdate = 0

---What the timeline is currently showing, refreshed on every draw.
---
---Kept because the alternative is that the only readable copy of these numbers
---is a dozen textures' geometry. `/ps status` reads it, and so does the offline
---harness - which is the only way the placement of the nodes gets checked at
---all, since neither this machine nor CI can open the game.
Timeline.state = {
	shown = false,
	preview = false,
	nodes = {},
}

-- Redrawing every frame buys nothing: the numbers move in seconds and the eye
-- cannot read faster than this anyway.
local UPDATE_INTERVAL = 0.1

-- How much room past the pool's slow quarter the axis leaves, so a run that is
-- behind still has somewhere to go before it saturates.
local HEADROOM = 1.15

-- Geometry, in pixels. The track is inset from the frame edges by more than half
-- a node so that a boss at second zero and a marker at the far right are drawn
-- whole rather than clipped against the panel.
local TRACK_INSET = 14
local TRACK_HEIGHT = 20
local FRAME_HEIGHT = 58
local NODE_SIZE = 9
local RANGE_HEIGHT = 6
local RAIL_HEIGHT = 2
local TRAIL_HEIGHT = 3
local LINK_HEIGHT = 2
local MARKER_SIZE = 11

local MIN_WIDTH, MAX_WIDTH = 240, 640

--------------------------------------------------------------------------------
-- The preview
--
-- The timeline only ever draws during a key, which makes it the one surface here
-- that cannot be looked at while deciding where to put it. Dragging a frame you
-- cannot see, then walking into a +10 to find out, is not a way to lay out a UI.
--
-- So: a fabricated dungeon on a clock that sweeps, fed through the SAME Refresh
-- that a real run uses. A preview drawn by its own code path would be a second
-- renderer that agrees with the first only until one of them changes.
--------------------------------------------------------------------------------

-- Deliberately not read from the published pool. These numbers never move, so
-- the timeline looks identical every time it is opened - which is what makes it
-- usable for judging size and position - and no published figure can drift under
-- a layout decision that was made against it.
--
-- `actual` is the fabricated kill time. The first boss is ahead of its pace and
-- the second is behind it on purpose: a sample that only ever showed one of the
-- two colours would let the other ship broken.
local PREVIEW_BOSSES = {
	{ id = -1, order = 1, name = "First Boss",  split = 300,  fast = 262,  slow = 348,  runs = 121, actual = 276 },
	{ id = -2, order = 2, name = "Second Boss", split = 620,  fast = 559,  slow = 702,  runs = 118, actual = 664 },
	{ id = -3, order = 3, name = "Third Boss",  split = 980,  fast = 896,  slow = 1078, runs = 96,  actual = 1002 },
	{ id = -4, order = 4, name = "Last Boss",   split = 1420, fast = 1308, slow = 1562, runs = 88,  actual = 1398 },
}

-- Seconds for the marker to travel the whole axis once. A real key takes half an
-- hour; this has to be long enough to read at each point and short enough that
-- somebody placing the frame is not waiting on it.
local PREVIEW_SWEEP = 16

-- Where the sweep opens. Two bosses down and the third still ahead, so the first
-- thing drawn is the state that shows the most: a mark ahead of its pace, a mark
-- behind it, a pending boss with its range block, and the marker between them.
-- Opening at zero would show an empty rail, which says the least about a layout.
local PREVIEW_START = 800

---When previewing, the `GetTime()` the sweep started at. Nil otherwise, and it
---is the only thing that says the timeline is showing something invented.
local previewFrom = nil

---The seconds the sample's axis spans, worked out the same way Refresh works out
---a real one's. Computed rather than written down so the sample cannot drift out
---of agreement with the drawing code that has to place PREVIEW_START on it.
---@return number seconds
local function previewScale()
	local scale = 0
	for _, boss in ipairs(PREVIEW_BOSSES) do
		scale = math.max(scale, boss.split, boss.slow)
	end
	return scale * HEADROOM
end

---A theme colour as four numbers, with a literal fallback.
---
---Indexed rather than unpacked on purpose. `unpack` is a Lua 5.1 global that WoW
---provides and 5.4 moved to `table.unpack`, so reaching for it here would work in
---game and break in the offline harness - which is the only place the geometry
---gets checked at all.
---@param key string a Theme.Colors key
---@param fallback number[] r, g, b, a
local function colour(key, fallback)
	local c = C[key]
	if type(c) ~= "table" then
		c = fallback
	end
	return c[1], c[2], c[3], c[4] or 1
end

-- One ramp, darkest to brightest, and the order is the hierarchy: the rail is
-- ground, a boss still ahead is the brightest neutral on it, and a boss already
-- down steps back down to sit between the two - dim enough to read as settled,
-- bright enough to still be the reference its kill mark is measured from.
--
-- `spent` deliberately does not go all the way to the rail's own value. A pace
-- node that disappears into the line takes the meaning of the link with it: the
-- gap has to be a gap between two visible things.
local PALETTE = {
	rail = { "border", { 0.176, 0.176, 0.176, 1 } },
	range = { "borderHover", { 0.290, 0.290, 0.290, 1 } },
	spent = { "borderHover", { 0.290, 0.290, 0.290, 1 } },
	trail = { "textMuted", { 0.580, 0.580, 0.580, 1 } },
	pace = { "textMuted", { 0.580, 0.580, 0.580, 1 } },
	finish = { "textSec", { 0.725, 0.725, 0.725, 1 } },

	-- The only two that carry a verdict, and never the only place one is said.
	ahead = { "accent", { 0.506, 0.549, 0.973, 1 } },
	behind = { "danger", { 0.973, 0.443, 0.443, 1 } },
}

---@param name string a PALETTE key
---@return number r, number g, number b, number a
local function paint(name)
	local entry = PALETTE[name]
	return colour(entry[1], entry[2])
end

---Whether the marker got the collection's round art, or fell back to a square.
---Decided once, because the two are recoloured by different calls and asking
---every tenth of a second is a texture swap nobody sees.
local markerIsArt = false

---Recolour the marker in place.
---@param name string a PALETTE key
local function tintMarker(name)
	local r, g, b, a = paint(name)
	if markerIsArt then
		marker:SetVertexColor(r, g, b, a)
	else
		marker:SetColorTexture(r, g, b, a)
	end
end

---Centre a texture on the rail at `x` pixels from the track's left edge.
---@param tex table
---@param x number
---@param w number
---@param h number
local function place(tex, x, w, h)
	tex:ClearAllPoints()
	tex:SetSize(math.max(1, w), h)
	tex:SetPoint("CENTER", track, "LEFT", x, 0)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

---The width the frame should be, clamped to what the layout can actually draw.
---
---A timeline is the one Peavers frame whose usefulness is mostly its width: four
---bosses and their ranges on 200 pixels is a row of touching blocks. The floor is
---not a preference, it is the point below which the display stops being one.
---@return number width
local function configuredWidth()
	local want = tonumber(PS.Config.barWidth) or 340
	return math.max(MIN_WIDTH, math.min(MAX_WIDTH, want))
end

---Both drag handlers, shared by the frame and by every node on it.
---
---Nodes take the mouse so they can carry a tooltip, and a mouse-enabled child
---silently swallows the drag of the frame underneath it. Forwarding rather than
---disabling keeps the whole surface draggable: a player grabbing the middle of
---the timeline is grabbing a boss node more often than not.
local function startDrag()
	if not PS.Config.lockBar then
		frame:StartMoving()
	end
end

local function stopDrag()
	frame:StopMovingOrSizing()
	local point, _, relativePoint, x, y = frame:GetPoint()
	PS.Config.barPoint = point
	PS.Config.barRelativePoint = relativePoint
	PS.Config.barX = x
	PS.Config.barY = y
	PS.Config:Save()
end

---What a boss node says when you point at it.
---
---The face of the timeline is deliberately wordless - four boss names across
---340 pixels is not a display, it is a paragraph - so the names and the exact
---figures live here, one boss at a time, on demand.
local function nodeTooltip(node)
	local tooltip = _G.GameTooltip
	if not tooltip or not node.boss then
		return
	end

	local boss = node.boss
	tooltip:SetOwner(node, "ANCHOR_TOP")
	tooltip:AddLine(boss.name or "?")
	tooltip:AddDoubleLine("Pace", PS.Pace.Clock(boss.split), 0.725, 0.725, 0.725, 1, 1, 1)

	if node.actual then
		local r, g, b = paint(node.actual > boss.split and "behind" or "ahead")
		tooltip:AddDoubleLine("Killed", PS.Pace.Clock(node.actual), 0.725, 0.725, 0.725, 1, 1, 1)
		tooltip:AddDoubleLine("", PS.Pace.Delta(node.actual - boss.split), 1, 1, 1, r, g, b)
	end

	tooltip:AddDoubleLine("Usual range",
		("%s - %s"):format(PS.Pace.Clock(boss.fast), PS.Pace.Clock(boss.slow)),
		0.725, 0.725, 0.725, 1, 1, 1)

	if boss.runs then
		tooltip:AddDoubleLine("Sample", ("%d runs"):format(boss.runs), 0.725, 0.725, 0.725, 1, 1, 1)
	end

	tooltip:Show()
end

local function hideTooltip()
	local tooltip = _G.GameTooltip
	if tooltip then
		tooltip:Hide()
	end
end

---One boss's furniture: its range block, its pace node, and - once it is down -
---the mark where it actually died and the link back to the pace it was measured
---against.
---
---A Frame rather than four loose textures because it is also the hit area for
---the tooltip, and because the frame level is what puts a node above the rail
---and below the marker without depending on the order things were created in.
---@param index number
---@return table node
local function acquireNode(index)
	local node = nodes[index]
	if node then
		return node
	end

	node = CreateFrame("Frame", nil, track)
	node:SetFrameLevel(track:GetFrameLevel() + 2)
	node:EnableMouse(true)
	node:RegisterForDrag("LeftButton")
	node:SetScript("OnDragStart", startDrag)
	node:SetScript("OnDragStop", stopDrag)
	node:SetScript("OnEnter", nodeTooltip)
	node:SetScript("OnLeave", hideTooltip)

	node.range = node:CreateTexture(nil, "BORDER")
	node.link = node:CreateTexture(nil, "ARTWORK")
	node.pace = node:CreateTexture(nil, "OVERLAY")
	node.mark = node:CreateTexture(nil, "OVERLAY")

	nodes[index] = node
	return node
end

function Timeline:Initialize()
	if frame then
		return
	end

	frame = CreateFrame("Frame", "PeaversSplitsTimeline", UIParent)
	frame:SetSize(configuredWidth(), FRAME_HEIGHT)
	frame:SetPoint(
		PS.Config.barPoint or "CENTER",
		UIParent,
		PS.Config.barRelativePoint or "CENTER",
		PS.Config.barX or 0,
		PS.Config.barY or 200)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", startDrag)
	frame:SetScript("OnDragStop", stopDrag)

	panelBg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
	panelBg:SetAllPoints()
	panelBg:SetColorTexture(colour("bgPanel", { 0.086, 0.086, 0.086, 1 }))

	headerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headerText:SetPoint("TOPLEFT", 10, -6)
	headerText:SetJustifyH("LEFT")
	headerText:SetTextColor(colour("textSec", { 0.725, 0.725, 0.725, 1 }))

	deltaText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	deltaText:SetPoint("TOPRIGHT", -10, -6)
	deltaText:SetJustifyH("RIGHT")

	track = CreateFrame("Frame", nil, frame)
	track:SetPoint("TOPLEFT", TRACK_INSET, -22)
	track:SetPoint("TOPRIGHT", -TRACK_INSET, -22)
	track:SetHeight(TRACK_HEIGHT)

	-- Ground for the instrument, and only for the instrument. With the panel
	-- switched off the rail is a dark grey hairline over whatever the world
	-- happens to be behind it, which over stone is nothing at all - so the strip
	-- the readings actually sit on stays, narrowed from a 58px box to the 20px
	-- that has something drawn on it. See SetChrome.
	trackBg = track:CreateTexture(nil, "BACKGROUND", nil, -2)
	trackBg:SetAllPoints()
	trackBg:SetColorTexture(0, 0, 0, 0.55)

	-- The run, end to end. Everything else is drawn against this one line.
	rail = track:CreateTexture(nil, "BACKGROUND")
	rail:SetColorTexture(paint("rail"))
	rail:SetHeight(RAIL_HEIGHT)
	rail:SetPoint("LEFT")
	rail:SetPoint("RIGHT")

	-- Where the run has already been. Subordinate to the marker on purpose: it is
	-- the trail behind a moving thing, not a fill that has to be read.
	trail = track:CreateTexture(nil, "BORDER")
	trail:SetColorTexture(paint("trail"))
	trail:SetHeight(TRAIL_HEIGHT)
	trail:SetPoint("LEFT")

	-- The last boss's pace, as a line rather than only as a node, because it is
	-- the end of the comparable run and the axis needs a visible end.
	finishLine = track:CreateTexture(nil, "BORDER")
	finishLine:SetColorTexture(paint("finish"))
	finishLine:SetWidth(1)

	finishText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	finishText:SetTextColor(colour("textMuted", { 0.580, 0.580, 0.580, 1 }))

	-- Above every node, so the marker is still readable where it sits on top of a
	-- boss - which is exactly the moment anybody is looking at it.
	local markerLayer = CreateFrame("Frame", nil, track)
	markerLayer:SetAllPoints()
	markerLayer:SetFrameLevel(track:GetFrameLevel() + 6)

	playhead = markerLayer:CreateTexture(nil, "ARTWORK")
	playhead:SetWidth(1)

	-- A dot, because it is the one thing on here that is not a boss and should not
	-- read as one. Theme.Dot already falls back to a square where the art is
	-- missing; the guard is for the offline harness, which stubs PeaversCommons
	-- down to what these addons call and has no Theme at all.
	marker = markerLayer:CreateTexture(nil, "OVERLAY")
	marker:SetSize(MARKER_SIZE, MARKER_SIZE)
	if Theme and Theme.Textures and Theme.Textures.circle then
		marker:SetTexture(Theme.Textures.circle)
		-- Asked rather than assumed: the collection's art is a file on disk that a
		-- half-updated PeaversCommons can be missing, and a texture that failed to
		-- load answers SetVertexColor without complaint and draws nothing at all.
		markerIsArt = marker:GetTexture() ~= nil
	end
	if not markerIsArt then
		marker:SetColorTexture(paint("ahead"))
	end

	-- Every reading here has to survive being read off a transparent frame over
	-- whatever the world is doing behind it. A shadow is one draw call and it is
	-- what stops the delta - the half a colour-blind reader has - from washing out
	-- against a snowfield.
	for _, fontString in ipairs({ headerText, deltaText, finishText }) do
		fontString:SetShadowColor(0, 0, 0, 1)
		fontString:SetShadowOffset(1, -1)
	end

	self:SetChrome()

	frame:SetScript("OnUpdate", function(_, elapsed)
		lastUpdate = lastUpdate + elapsed
		if lastUpdate < UPDATE_INTERVAL then
			return
		end
		lastUpdate = 0
		Timeline:Refresh()
	end)

	frame:Hide()
	PeaversCommons.Utils.Debug(PS, "timeline created")
end

---Show or hide the panel, and put the instrument's own ground back when it goes.
---
---Two textures rather than one, because "no background" and "unreadable" are not
---the same request. Switching the panel off is asking for the box to stop sitting
---on the screen; it is not asking for a dark-grey hairline to be drawn over dark
---grey stone. So the 58px box goes and a 20px strip stays under the part that has
---readings on it - and when the panel IS on, that strip would only be a second
---background over the first, so it does not draw.
function Timeline:SetChrome()
	if not frame then
		return
	end

	local panel = PS.Config.showBackground and true or false
	if panel then
		panelBg:Show()
		trackBg:Hide()
	else
		panelBg:Hide()
		trackBg:Show()
	end

	self.state.background = panel
end

---Re-read the configured width. Called from the settings slider.
function Timeline:ApplyWidth()
	if not frame then
		return
	end
	frame:SetWidth(configuredWidth())
	self:Refresh()
end

--------------------------------------------------------------------------------
-- What the run is being drawn against
--------------------------------------------------------------------------------

---Every boss of this key, in the order the group will walk them.
---
---Ordered by `order` (the journal's) rather than by pace, because that is the
---route. The comparison falls through to the pace and then to the id, and the id
---is not decoration: `pairs` has no defined order, so a sort whose comparison can
---return false both ways would put two bosses in a different sequence from one
---frame to the next, and the nodes would swap places while somebody watched.
---@param mapID number|nil
---@param level number|nil
---@return table[]|nil bosses
local function bossList(mapID, level)
	local api = PS.GetDataAPI()
	if not api or not mapID or not level then
		return nil
	end

	local bosses = api.GetBosses(mapID, level)
	if not bosses then
		return nil
	end

	local list = {}
	for encounterID, boss in pairs(bosses) do
		list[#list + 1] = {
			id = encounterID,
			order = boss.order or 99,
			name = boss.name,
			split = boss.split,
			fast = boss.fast or boss.split,
			slow = boss.slow or boss.split,
			runs = boss.runs,
		}
	end

	if #list == 0 then
		return nil
	end

	table.sort(list, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		if a.split ~= b.split then
			return a.split < b.split
		end
		return a.id < b.id
	end)

	return list
end

--------------------------------------------------------------------------------
-- Preview control
--------------------------------------------------------------------------------

---Whether the timeline is currently showing invented numbers.
---@return boolean
function Timeline:IsPreviewing()
	return previewFrom ~= nil
end

---Turn the preview on or off.
---
---`showBar` is deliberately not consulted: asking for the sample is a more
---specific instruction than the checkbox, and someone who has the timeline
---switched off is exactly the person who wants to see what they are switching on.
---@param on boolean
function Timeline:SetPreview(on)
	if on and PS.Run.active then
		-- A real key is running and its numbers are the ones that matter.
		PeaversCommons.Utils.Print(PS, "not while a key is running - the timeline is showing the real thing.")
		return
	end

	if on then
		previewFrom = GetTime() - PREVIEW_SWEEP * (PREVIEW_START / previewScale())
	else
		previewFrom = nil
	end

	self:Update()
end

---@return boolean previewing the state after the toggle
function Timeline:TogglePreview()
	self:SetPreview(not self:IsPreviewing())
	return self:IsPreviewing()
end

---Seconds into the run, the bosses on the route, and which of them are down -
---from the live key, or from the preview. One source, so both go through the
---same drawing code below.
---@return number|nil elapsed, table[]|nil bosses, table|nil killed
function Timeline:Source()
	-- A real key always wins, and reclaims the timeline without anybody having to
	-- remember to turn the preview off first.
	if previewFrom and PS.Run.active then
		previewFrom = nil
	end

	if previewFrom then
		local elapsed =
			(((GetTime() - previewFrom) % PREVIEW_SWEEP) / PREVIEW_SWEEP) * previewScale()

		-- Derived from the sweep rather than remembered, so the fabricated run
		-- un-kills itself on the way round and the loop has no state to reset.
		local killed = {}
		for _, boss in ipairs(PREVIEW_BOSSES) do
			if elapsed >= boss.actual then
				killed[boss.id] = boss.actual
			end
		end

		return elapsed, PREVIEW_BOSSES, killed
	end

	local run = PS.Run
	if not (PS.Config.showBar and run.active) then
		return nil, nil, nil
	end

	return run:GetElapsed(), bossList(run.mapID, run.level), run.killed
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

---Stop drawing, and say in the state that nothing is drawn.
local function blank()
	frame:Hide()
	Timeline.state.shown = false
	Timeline.state.preview = false
	Timeline.state.nodes = {}
end

function Timeline:Refresh()
	if not frame then
		return
	end

	local elapsed, bosses, killed = self:Source()

	-- No pool for this level: the axis has no bosses on it and no end, and a rail
	-- with one dot sliding along it is not an instrument. Hide rather than draw
	-- something that looks like a measurement.
	if not (elapsed and bosses) then
		blank()
		return
	end

	killed = killed or {}

	-- The axis. The finish is the LAST boss on the route - the end of the run that
	-- can be compared at all - while the scale also has to hold any range block
	-- that reaches past it, plus headroom for an overrun.
	local finish = bosses[#bosses].split
	local scale = finish
	for _, boss in ipairs(bosses) do
		scale = math.max(scale, boss.split, boss.slow)
	end
	scale = scale * HEADROOM

	if scale <= 0 then
		blank()
		return
	end

	frame:Show()
	self.state.shown = true

	local width = track:GetWidth()
	if not width or width <= 0 then
		return
	end

	local function at(seconds)
		return math.max(0, math.min(1, (seconds or 0) / scale)) * width
	end

	--------------------------------------------------------------------------
	-- What is being raced, and by how much
	--------------------------------------------------------------------------

	-- The next boss still standing, by the route. Once they are all down the
	-- comparison is settled: the delta freezes at the last kill rather than
	-- carrying on growing against a boss that is already dead.
	local next_, lastKill, lastKilled
	for _, boss in ipairs(bosses) do
		local at_ = killed[boss.id]
		if at_ then
			if not lastKill or at_ > lastKill then
				lastKill, lastKilled = at_, boss
			end
		elseif not next_ then
			next_ = boss
		end
	end

	local delta, header
	if next_ then
		delta = elapsed - next_.split
		header = ("%s  Next: %s"):format(PS.Pace.Clock(elapsed), next_.name or "?")
	elseif lastKilled then
		delta = lastKill - lastKilled.split
		header = ("%s  all bosses down"):format(PS.Pace.Clock(elapsed))
	else
		delta = 0
		header = PS.Pace.Clock(elapsed)
	end

	-- Invented numbers have to say so on their face. Someone glancing at this
	-- should never be able to read a fabricated run as their own.
	if previewFrom then
		header = "Preview: " .. header
	end

	local behind = delta > 0.5
	local tone = behind and "behind" or "ahead"

	--------------------------------------------------------------------------
	-- The axis furniture
	--------------------------------------------------------------------------

	local finishX = at(finish)
	finishLine:ClearAllPoints()
	finishLine:SetPoint("TOP", track, "TOPLEFT", finishX, 0)
	finishLine:SetPoint("BOTTOM", track, "BOTTOMLEFT", finishX, 0)

	finishText:SetText(PS.Pace.Clock(finish))
	local half = (finishText:GetStringWidth() or 0) / 2
	finishText:ClearAllPoints()
	finishText:SetPoint("TOP", track, "BOTTOMLEFT",
		math.max(half, math.min(width - half, finishX)), -3)

	-- Where the run has already been. Deliberately NOT coloured by the current
	-- delta: the trail covers the whole run so far, and repainting all of it red
	-- the moment the group falls behind at the fourth boss would make a claim
	-- about the first three that the marks sitting on it flatly contradict. The
	-- verdict belongs to the marker, the words, and each kill's own mark.
	local markerX = at(elapsed)
	trail:SetWidth(math.max(1, markerX))

	--------------------------------------------------------------------------
	-- The bosses
	--------------------------------------------------------------------------

	local drawn = {}

	for index, boss in ipairs(bosses) do
		local node = acquireNode(index)
		local paceX = at(boss.split)
		local left, right = at(boss.fast), at(boss.slow)
		local actual = killed[boss.id]

		node.boss = boss
		node.actual = actual

		-- The middle half of the pool, as ground rather than as a mark. A delta of
		-- forty seconds means very little on a boss whose middle half spans four
		-- minutes, and this is that sentence drawn instead of said.
		place(node.range, (left + right) / 2, right - left, RANGE_HEIGHT)
		node.range:SetColorTexture(paint("range"))
		node.range:Show()

		-- The pace. It dims once the boss is down: it stops being the thing being
		-- raced and becomes the reference the mark is measured from.
		place(node.pace, paceX, NODE_SIZE, NODE_SIZE)
		node.pace:SetColorTexture(paint(actual and "spent" or "pace"))
		node.pace:Show()

		local markX, extent
		if actual then
			markX = at(actual)
			-- The gap, drawn to scale. Its length IS the delta, which is the one
			-- reading on here that survives a monitor with no red on it.
			place(node.link, (paceX + markX) / 2, math.abs(markX - paceX), LINK_HEIGHT)
			node.link:SetColorTexture(paint(actual > boss.split and "behind" or "ahead"))
			node.link:Show()

			place(node.mark, markX, NODE_SIZE, NODE_SIZE)
			node.mark:SetColorTexture(paint(actual > boss.split and "behind" or "ahead"))
			node.mark:Show()

			extent = { math.min(left, paceX, markX), math.max(right, paceX, markX) }
		else
			node.link:Hide()
			node.mark:Hide()
			extent = { math.min(left, paceX), math.max(right, paceX) }
		end

		-- The hit area covers everything this boss drew, so pointing anywhere at
		-- its range block or its delta names the boss.
		local lo = extent[1] - NODE_SIZE / 2
		local hi = extent[2] + NODE_SIZE / 2
		node:ClearAllPoints()
		node:SetPoint("LEFT", track, "LEFT", lo, 0)
		node:SetSize(math.max(NODE_SIZE, hi - lo), TRACK_HEIGHT)
		node:Show()

		drawn[index] = {
			id = boss.id,
			name = boss.name,
			paceX = paceX,
			rangeLeft = left,
			rangeWidth = math.max(1, right - left),
			killed = actual ~= nil,
			actualX = markX,
			delta = actual and (actual - boss.split) or nil,
		}
	end

	-- A shorter dungeon than the last one drawn leaves nodes behind. They are kept
	-- rather than destroyed - frames cannot be - so they have to be put away.
	for index = #bosses + 1, #nodes do
		nodes[index]:Hide()
		nodes[index].boss = nil
		nodes[index].actual = nil
	end

	--------------------------------------------------------------------------
	-- You
	--------------------------------------------------------------------------

	playhead:ClearAllPoints()
	playhead:SetPoint("TOP", track, "TOPLEFT", markerX, 0)
	playhead:SetPoint("BOTTOM", track, "BOTTOMLEFT", markerX, 0)
	local r, g, b = paint(tone)
	playhead:SetColorTexture(r, g, b, 0.35)

	tintMarker(tone)
	marker:ClearAllPoints()
	marker:SetPoint("CENTER", track, "LEFT", markerX, 0)

	--------------------------------------------------------------------------
	-- The words, which are the half a colour-blind reader has
	--------------------------------------------------------------------------

	local phrase = PS.Pace.Delta(delta)
	headerText:SetText(header)
	deltaText:SetText(phrase)

	local dr, dg, db, da = paint(tone)
	deltaText:SetTextColor(dr, dg, db, da)

	local state = self.state
	state.preview = previewFrom ~= nil
	state.header = header
	state.delta = phrase
	state.clock = PS.Pace.Clock(elapsed)
	state.scale = scale
	state.width = width
	state.markerX = markerX
	state.finishX = finishX
	state.finish = finish
	state.tone = tone
	state.nodes = drawn
end

---A SNAPSHOT of what the timeline is currently showing. See `Timeline.state`.
---
---A copy, not the live table. The internal one is overwritten ten times a second,
---so handing it out would give a caller something that changes under them between
---two reads - which is not a hypothetical: it is exactly how the offline harness
---first "proved" that a run ahead of the pace was drawn in the danger red, having
---compared two references to the same mutated table.
---@return table state
function Timeline:GetState()
	local out = {}
	for k, v in pairs(self.state) do
		if k == "nodes" and type(v) == "table" then
			local copy = {}
			for index, node in ipairs(v) do
				local one = {}
				for key, value in pairs(node) do
					one[key] = value
				end
				copy[index] = one
			end
			out[k] = copy
		else
			out[k] = v
		end
	end
	return out
end

---Show or hide in one call, for the config toggles and the run lifecycle.
function Timeline:Update()
	if not frame then
		return
	end
	self:SetChrome()
	self:Refresh()
end
