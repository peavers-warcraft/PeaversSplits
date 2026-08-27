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

	local note = W:CreateLabel(parentFrame,
		"Party chat only - a split is about the group's run. Outside a group, and " ..
		"whenever a channel is unavailable, the line goes to your own chat frame instead.",
		{ width = width, wrap = true })
	note:SetPoint("TOPLEFT", indent, y)
	y = y - 40

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
	local barNote = W:CreateLabel(parentFrame,
		"Drag it to move it. The track runs to a little past the pool's slow " ..
		"quarter, the shaded block is its middle half, and the line is the pace " ..
		"itself - so being inside the block is something you can see rather than " ..
		"something you have to be told.",
		{ width = width, wrap = true })
	barNote:SetPoint("TOPLEFT", indent, y)
	y = y - 56

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
	local spreadNote = W:CreateLabel(parentFrame,
		"The published pace carries the middle half of the pool as well as its " ..
		"middle. Being forty seconds off means very little on a boss where that " ..
		"middle half spans four minutes, so saying when a split lands inside it " ..
		"is what keeps a number from reading as a verdict.",
		{ width = width, wrap = true })
	spreadNote:SetPoint("TOPLEFT", indent, y)

	return parentFrame
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

	local note = W:CreateLabel(parentFrame, body, { width = width, wrap = true })
	note:SetPoint("TOPLEFT", indent, y)

	return parentFrame
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
