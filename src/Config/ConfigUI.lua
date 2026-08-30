--------------------------------------------------------------------------------
-- PeaversSplits settings
--
-- Announcement preferences ONLY. There is deliberately no pace editor anywhere
-- in this UI: the benchmark is a published pool and is read-only. "Users cannot
-- edit" means there is no in-game editing surface and nothing timing-shaped is
-- persisted - it does not mean the Lua on disk is tamper-proof, and it would be
-- dishonest to imply otherwise.
--
-- Note also that SAY and YELL are not offered as channels, and that is a
-- decision rather than an omission. They reach everyone standing nearby, none of
-- whom installed this or asked to be told about somebody else's key.
--------------------------------------------------------------------------------

local _, PS = ...

local ConfigUI = {}
PS.ConfigUI = ConfigUI

local PeaversCommons = _G.PeaversCommons
if not PeaversCommons then
	print("|cffff0000Error:|r PeaversCommons not found.")
	return
end

local W = PeaversCommons.Widgets

local function ResolveWidth(parentFrame, indent)
	local parentWidth = parentFrame:GetWidth() or 0
	if parentWidth > 100 then
		return parentWidth - (indent * 2) - 10
	end
	return 360
end

-- A wrapped note is as tall as the wrapping makes it, which depends on the
-- panel width and so is not knowable while writing the page. Measure it instead
-- of advancing by a constant: a constant is right for one string at one width
-- and silently overlaps the next thing the moment either changes.
local NOTE_GAP = 16

local function AddNote(parentFrame, text, indent, y, width)
	local note = W:CreateLabel(parentFrame, text, { width = width, wrap = true })
	note:SetPoint("TOPLEFT", indent, y)
	-- Fall back to one line's worth if the font has not resolved a height yet,
	-- so the worst case is a cramped page rather than text drawn over text.
	local height = note:GetStringHeight() or 0
	if height <= 0 then
		height = 14
	end
	return note, y - height - NOTE_GAP
end

-- Every other Peavers page ends this way. The page is a scroll child, and a
-- scroll frame takes its scroll range from the child's height - leaving it at
-- the 1px PeaversConfig creates it with means the bottom of a long page cannot
-- be reached at all.
local function FinishPage(parentFrame, y)
	parentFrame:SetHeight(math.abs(y) + 30)
	return parentFrame
end

--------------------------------------------------------------------------------
-- Announcements
--------------------------------------------------------------------------------

function ConfigUI:BuildAnnouncementsPage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "Announcements", indent, y)
	y = newY - 8

	local enabled = W:CreateCheckbox(parentFrame, "Call out splits", {
		checked = PS.Config.announceEnabled,
		width = width,
		onChange = function(checked)
			PS.Config.announceEnabled = checked
			PS.Config:Save()
		end,
	})
	enabled:SetPoint("TOPLEFT", indent, y)
	y = y - 28

	local channel = W:CreateDropdown(parentFrame, "Where to send them", {
		width = 220,
		selected = PS.Config.channel,
		options = {
			{ value = "PARTY", label = "Party chat" },
			{ value = "self", label = "Only me" },
		},
		onChange = function(value)
			PS.Config.channel = value
			PS.Config:Save()
		end,
	})
	channel:SetPoint("TOPLEFT", indent, y)
	y = y - 56

	local _, noteY = AddNote(parentFrame,
		"Party chat only - a split is about the group's run. Outside a group, and " ..
		"whenever a channel is unavailable, the line goes to your own chat frame instead.",
		indent, y, width)
	y = noteY - 8

	local _, barY = W:CreateSectionHeader(parentFrame, "The live bar", indent, y)
	y = barY - 8

	local barOptions = {
		{ key = "showBar", label = "Show the pace bar during a key" },
		{ key = "lockBar", label = "Lock it in place" },
	}

	for _, option in ipairs(barOptions) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PS.Config[option.key],
			width = width,
			onChange = function(checked)
				PS.Config[option.key] = checked
				PS.Config:Save()
				PS.PaceBar:Update()
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	y = y - 8

	-- The bar otherwise only exists during a key, so its size and position had to
	-- be chosen blind and checked by walking into a dungeon. This draws it with a
	-- sample boss on a looping clock, through the real rendering path.
	local function previewLabel()
		return PS.PaceBar:IsPreviewing() and "Hide the test bar" or "Show a test bar"
	end

	local previewButton
	previewButton = W:CreateButton(parentFrame, previewLabel(), {
		width = 150,
		onClick = function()
			PS.PaceBar:TogglePreview()
			-- Read the state back rather than assuming the toggle took: it refuses
			-- while a key is running, and a button that lies about which way it went
			-- is worse than one that does nothing.
			previewButton:SetLabel(previewLabel())
		end,
	})
	previewButton:SetPoint("TOPLEFT", indent, y)
	y = y - 34

	local _, barNoteY = AddNote(parentFrame,
		"Drag it to move it. The track runs to a little past the pool's slow " ..
		"quarter, the shaded block is its middle half, and the line is the pace " ..
		"itself - so being inside the block is something you can see rather than " ..
		"something you have to be told.\n\n" ..
		"The test bar sweeps a sample boss so you can place it outside a key. Its " ..
		"numbers are invented and it says so in its header; a real key takes the " ..
		"bar back automatically.",
		indent, y, width)
	y = barNoteY - 8

	local _, headerY = W:CreateSectionHeader(parentFrame, "What to include", indent, y)
	y = headerY - 8

	local checkboxes = {
		{
			key = "showSpread",
			label = "Say when a split is inside the usual range",
		},
		{
			key = "showSampleSize",
			label = "Include how many runs the pace is built from",
		},
		{
			key = "announceStart",
			label = "Say what the run is being paced against, at the start",
		},
		{
			key = "announceFinish",
			label = "Sum up when the key finishes",
		},
	}

	for _, option in ipairs(checkboxes) do
		local checkbox = W:CreateCheckbox(parentFrame, option.label, {
			checked = PS.Config[option.key],
			width = width,
			onChange = function(checked)
				PS.Config[option.key] = checked
				PS.Config:Save()
			end,
		})
		checkbox:SetPoint("TOPLEFT", indent, y)
		y = y - 28
	end

	y = y - 12
	local _, spreadNoteY = AddNote(parentFrame,
		"The published pace carries the middle half of the pool as well as its " ..
		"middle. Being forty seconds off means very little on a boss where that " ..
		"middle half spans four minutes, so saying when a split lands inside it " ..
		"is what keeps a number from reading as a verdict.",
		indent, y, width)

	return FinishPage(parentFrame, spreadNoteY)
end

--------------------------------------------------------------------------------
-- The pace itself
--------------------------------------------------------------------------------

function ConfigUI:BuildPacePage(parentFrame)
	local y = -10
	local indent = 25
	local width = ResolveWidth(parentFrame, indent)

	local _, newY = W:CreateSectionHeader(parentFrame, "The Pace You Are Racing", indent, y)
	y = newY - 8

	local api = PS.GetDataAPI()

	local body
	if not api then
		body = "PeaversSplitsData is not installed, so there is nothing to compare " ..
			"against. Splits will still be called out as bosses die."
	else
		body = ("Pace comes from the published %s pool, last rebuilt %s.\n\n" ..
			"It is matched on your EXACT keystone level. A level with no published " ..
			"pool gets no comparison - not the nearest level, and not a blend. " ..
			"Enemy health scales per level, so a +14 measured against +12s would be " ..
			"told it is behind a pace nobody at +14 ever set."):format(
			tostring(api.GetPartition() or "?"),
			tostring(api.GetLastUpdate() or "unknown"))
	end

	local _, noteY = AddNote(parentFrame, body, indent, y, width)

	return FinishPage(parentFrame, noteY)
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

function ConfigUI:GetPages()
	return {
		-- First entry renders leftmost and is the default-selected tab
		{ key = "announcements", label = "Announcements", builder = function(f) ConfigUI:BuildAnnouncementsPage(f) end },
		{ key = "pace", label = "Pace", builder = function(f) ConfigUI:BuildPacePage(f) end },
	}
end

-- Legacy single-panel path, kept for the older ConfigRegistry `buildPanel` contract.
function ConfigUI:BuildIntoFrame(parentFrame)
	self:BuildAnnouncementsPage(parentFrame)
	return parentFrame
end

function ConfigUI:OpenOptions()
	local mainFrame = _G.PeaversConfig and _G.PeaversConfig.MainFrame
	if mainFrame then
		mainFrame:Show()
		if mainFrame.SelectAddon then
			mainFrame:SelectAddon("PeaversSplits")
		end
		return
	end

	if Settings and Settings.OpenToCategory then
		if PS.directSettingsCategoryID then
			local success = pcall(Settings.OpenToCategory, PS.directSettingsCategoryID)
			if success then return end
		end
		if PS.directCategoryID then
			local success = pcall(Settings.OpenToCategory, PS.directCategoryID)
			if success then return end
		end
	end

	if SettingsPanel then
		SettingsPanel:Open()
	end
end

function ConfigUI:Initialize()
end
