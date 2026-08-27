--------------------------------------------------------------------------------
-- PaceBar - the gap, while it is opening
--
-- The chat line is the record; this is the instrument. It answers "how are we
-- doing right now" continuously, against the NEXT boss's published pace, so the
-- group sees a gap widening rather than learning about it once the boss is
-- already down.
--
-- ## What the bar actually draws
--
-- The track is one boss's clock, running from zero to a little past the slow
-- quarter of the pool. On it:
--
--   * a BAND from p25 to p75 - the middle half of the pool, drawn as ground
--   * a TICK at the median - the pace itself
--   * a FILL from the left to where this run currently is
--
-- So "inside the band" is a thing you can see rather than a sentence you have to
-- be told, which is the same argument the website's widget makes: a delta of
-- forty seconds means nothing on a boss whose middle half spans four minutes.
--
-- The scale is FIXED at p75 plus a quarter of headroom, and deliberately does
-- not grow to fit. A track that rescales as the run overruns keeps the fill in
-- the same place while the numbers get worse, which is the opposite of what an
-- instrument is for. Past the right edge the bar simply saturates and the text
-- carries the number.
--
-- ## Colour is never the only signal
--
-- Ahead is the theme accent and behind is its danger red - and the delta is also
-- written out in words next to the bar, because a bar that only says "bad" in
-- red says nothing at all to a reader who cannot see the difference.
--
-- There is no green here on purpose: the Peavers palette has none, and inventing
-- one for this addon would be the one surface in the suite that does.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons
local Theme = PeaversCommons.Theme
local C = Theme and Theme.Colors or {}

local PaceBar = {}
PS.PaceBar = PaceBar

local frame, track, band, tick, fill, headerText, deltaText
local lastUpdate = 0

---What the bar is currently showing, refreshed on every draw.
---
---Kept because the alternative is that the only readable copy of these numbers
---is three textures' geometry. `/ps status` reads it, and so does the offline
---harness - which is the only way the placement of the tick and the band gets
---checked at all, since neither this machine nor CI can open the game.
PaceBar.state = {
	shown = false,
}

-- Redrawing every frame buys nothing: the numbers move in seconds and the eye
-- cannot read faster than this anyway.
local UPDATE_INTERVAL = 0.1

-- How much room past the slow quarter the track leaves, so a run that is behind
-- still has somewhere to go before it saturates.
local HEADROOM = 1.25

---A theme colour as four numbers, with a literal fallback.
---
---Indexed rather than unpacked on purpose. `unpack` is a Lua 5.1 global that
---WoW provides and 5.4 moved to `table.unpack`, so reaching for it here would
---work in game and break in the offline harness - which is the only place the
---bar's geometry gets checked at all.
---@param key string a Theme.Colors key
---@param fallback number[] r, g, b, a
local function colour(key, fallback)
	local c = C[key]
	if type(c) ~= "table" then
		c = fallback
	end
	return c[1], c[2], c[3], c[4] or 1
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function PaceBar:Initialize()
	if frame then
		return
	end

	frame = CreateFrame("Frame", "PeaversSplitsPaceBar", UIParent)
	frame:SetSize(260, 46)
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

	-- `dragged` rather than `self`: these close over PaceBar:Initialize's own
	-- `self`, and shadowing it is how a handler quietly ends up moving the wrong
	-- object the day somebody adds a line between them.
	frame:SetScript("OnDragStart", function(dragged)
		if not PS.Config.lockBar then
			dragged:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(dragged)
		dragged:StopMovingOrSizing()
		local point, _, relativePoint, x, y = dragged:GetPoint()
		PS.Config.barPoint = point
		PS.Config.barRelativePoint = relativePoint
		PS.Config.barX = x
		PS.Config.barY = y
		PS.Config:Save()
	end)

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(colour("bgPanel", { 0.086, 0.086, 0.086, 1 }))

	headerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headerText:SetPoint("TOPLEFT", 8, -6)
	headerText:SetJustifyH("LEFT")
	headerText:SetTextColor(colour("textSec", { 0.725, 0.725, 0.725, 1 }))

	deltaText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	deltaText:SetPoint("TOPRIGHT", -8, -6)
	deltaText:SetJustifyH("RIGHT")

	track = CreateFrame("Frame", nil, frame)
	track:SetPoint("BOTTOMLEFT", 8, 8)
	track:SetPoint("BOTTOMRIGHT", -8, 8)
	track:SetHeight(14)

	local trackBg = track:CreateTexture(nil, "BACKGROUND")
	trackBg:SetAllPoints()
	trackBg:SetColorTexture(colour("bgNested", { 0.110, 0.110, 0.110, 1 }))

	-- The pool's middle half, as ground rather than as a mark.
	band = track:CreateTexture(nil, "BORDER")
	band:SetColorTexture(colour("border", { 0.176, 0.176, 0.176, 1 }))

	-- The run itself, over the band so its position against it is readable.
	fill = track:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT")
	fill:SetPoint("BOTTOMLEFT")

	-- The pace, above everything - it is the thing being raced.
	tick = track:CreateTexture(nil, "OVERLAY")
	tick:SetColorTexture(colour("text", { 1, 1, 1, 1 }))
	tick:SetWidth(2)
	tick:SetPoint("TOP")
	tick:SetPoint("BOTTOM")

	frame:SetScript("OnUpdate", function(_, elapsed)
		lastUpdate = lastUpdate + elapsed
		if lastUpdate < UPDATE_INTERVAL then
			return
		end
		lastUpdate = 0
		PaceBar:Refresh()
	end)

	frame:Hide()
	PeaversCommons.Utils.Debug(PS, "pace bar created")
end

--------------------------------------------------------------------------------
-- What to race against next
--------------------------------------------------------------------------------

---The next boss this run has not killed, by the game's own ordering.
---
---Ordered by `order` (the journal's) rather than by pace, because that is the
---route the group is walking. Ties and missing orders fall back to the pace,
---which at least keeps the sequence monotonic.
---@param run table
---@return table|nil boss the benchmark entry
local function nextBoss(run)
	local api = PS.GetDataAPI()
	if not api then
		return nil
	end

	local bosses = api.GetBosses(run.mapID, run.level)
	if not bosses then
		return nil
	end

	local best
	for encounterID, boss in pairs(bosses) do
		if not run.killed[encounterID] then
			if not best
				or (boss.order or 99) < (best.order or 99)
				or ((boss.order or 99) == (best.order or 99) and boss.split < best.split) then
				best = boss
			end
		end
	end

	return best
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

function PaceBar:Refresh()
	if not frame then
		return
	end

	local run = PS.Run
	if not (PS.Config.showBar and run.active) then
		frame:Hide()
		self.state.shown = false
		return
	end

	local elapsed = run:GetElapsed()
	local boss = nextBoss(run)

	-- No pace for this level, or every boss already down: the bar has nothing to
	-- race against, and a bar with no reference is the lone-pin problem the
	-- website's widget already ran into. Hide rather than draw something.
	if not (elapsed and boss) then
		frame:Hide()
		self.state.shown = false
		return
	end

	frame:Show()
	self.state.shown = true

	local scale = math.max(boss.slow or boss.split, boss.split) * HEADROOM
	if scale <= 0 then
		frame:Hide()
		self.state.shown = false
		return
	end

	local width = track:GetWidth()
	if not width or width <= 0 then
		return
	end

	local function at(seconds)
		return math.max(0, math.min(1, seconds / scale)) * width
	end

	-- The middle half, as ground.
	local left, right = at(boss.fast or boss.split), at(boss.slow or boss.split)
	band:ClearAllPoints()
	band:SetPoint("TOPLEFT", track, "TOPLEFT", left, 0)
	band:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", left, 0)
	band:SetWidth(math.max(1, right - left))

	-- The pace.
	tick:ClearAllPoints()
	tick:SetPoint("TOP", track, "TOPLEFT", at(boss.split), 0)
	tick:SetPoint("BOTTOM", track, "BOTTOMLEFT", at(boss.split), 0)

	-- Where the run is.
	local delta = elapsed - boss.split
	local behind = delta > 0.5
	fill:SetWidth(math.max(1, at(elapsed)))
	if behind then
		fill:SetColorTexture(colour("danger", { 0.973, 0.443, 0.443, 1 }))
	else
		fill:SetColorTexture(colour("accent", { 0.506, 0.549, 0.973, 1 }))
	end

	local header = ("Next: %s"):format(boss.name or "?")
	local phrase = PS.Pace.Delta(delta)
	headerText:SetText(header)
	deltaText:SetText(phrase)

	local r, g, b, a
	if behind then
		r, g, b, a = colour("danger", { 0.973, 0.443, 0.443, 1 })
	else
		r, g, b, a = colour("accent", { 0.506, 0.549, 0.973, 1 })
	end
	deltaText:SetTextColor(r, g, b, a)

	local state = self.state
	state.header = header
	state.delta = phrase
	state.tick = at(boss.split)
	state.bandLeft = left
	state.bandWidth = math.max(1, right - left)
	state.fillWidth = math.max(1, at(elapsed))
	state.fillColour = { r, g, b, a }
end

---A SNAPSHOT of what the bar is currently showing. See `PaceBar.state`.
---
---A copy, not the live table. The internal one is overwritten ten times a
---second, so handing it out would give a caller something that changes under
---them between two reads - which is not a hypothetical: it is exactly how the
---offline harness first "proved" that a run ahead of the pace was drawn in the
---danger red, having compared two references to the same mutated table.
---@return table state
function PaceBar:GetState()
	local out = {}
	for k, v in pairs(self.state) do
		if k == "fillColour" and type(v) == "table" then
			out[k] = { v[1], v[2], v[3], v[4] }
		else
			out[k] = v
		end
	end
	return out
end

---Show or hide in one call, for the config toggle and the run lifecycle.
function PaceBar:Update()
	if not frame then
		return
	end
	self:Refresh()
end
