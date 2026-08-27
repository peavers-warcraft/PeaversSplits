local addonName, PS = ...

-- Access the PeaversCommons library
local PeaversCommons = _G.PeaversCommons

-- Initialize addon namespace
PS.name = addonName
PS.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.1.0"

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function PrintStatus()
	local Utils = PeaversCommons.Utils
	local api = PS.GetDataAPI()

	if not api then
		Utils.Print(PS, "data addon: |cffff5555missing|r")
		return
	end

	Utils.Print(PS, ("data addon: loaded, %s pool updated %s")
		:format(tostring(api.GetPartition() or "?"), tostring(api.GetLastUpdate() or "unknown")))

	local run = PS.Run
	if not run.active then
		Utils.Print(PS, "no keystone running.")
		return
	end

	local dungeon = api.GetDungeonName(run.mapID) or ("map " .. tostring(run.mapID))
	Utils.Print(PS, ("running %s +%s at %s%s"):format(
		dungeon,
		tostring(run.level),
		PS.Pace.Clock(run:GetElapsed() or 0),
		run.recovered and " (recovered after a reload)" or ""))

	-- What the run is actually being compared against, which is the question
	-- somebody types /ps status to answer.
	if api.GetBosses(run.mapID, run.level) then
		local down = 0
		for _ in pairs(run.killed) do
			down = down + 1
		end
		Utils.Print(PS, ("pacing against the published +%s pool - %d bosses down.")
			:format(tostring(run.level), down))
	else
		local levels = api.GetLevels(run.mapID)
		Utils.Print(PS, ("no pace published for +%s.%s"):format(
			tostring(run.level),
			(levels and #levels > 0) and (" Levels with data: " .. table.concat(levels, ", ") .. ".") or ""))
	end
end

PeaversCommons.SlashCommands:Register(addonName, "ps", {
	default = function()
		PrintStatus()
	end,
	-- Registered explicitly even though SlashCommands adds a `config` of its own.
	-- Its version resolves the addon table with _G[addonName], and this addon
	-- deliberately never publishes itself as a global - PeaversSplitsDB is the
	-- only name it puts in _G - so that lookup returns nil and the handler bails
	-- out before reaching any of its fallbacks. The result would be a documented
	-- command that silently did nothing.
	config = function()
		PS.ConfigUI:OpenOptions()
	end,
	status = function()
		PrintStatus()
	end,
})

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

PeaversCommons.Events:Init(addonName, function()
	PS.Config:Initialize()

	-- The TOC hard-dependency normally guarantees the Data addon, but Curse
	-- installs can desync. Say so plainly and carry on: every read of the API is
	-- nil-guarded, and the addon still calls out raw splits without a pool to
	-- compare them to, which is a degraded product rather than a broken one.
	if not PS.HasData() then
		PeaversCommons.Utils.Print(PS,
			"PeaversSplitsData is missing or outdated - splits will be called out with nothing to compare against.")
	end

	if PS.ConfigUI and PS.ConfigUI.Initialize then
		PS.ConfigUI:Initialize()
	end

	PS.PaceBar:Initialize()
	PS.Events:Initialize()

	-- Use the centralized SettingsUI system from PeaversCommons
	C_Timer.After(0.5, function()
		PeaversCommons.SettingsUI:CreateRedirectPage(PS, addonName, "Peavers Splits")
	end)

	-- Register with PeaversConfig registry
	if PeaversCommons.ConfigRegistry then
		PeaversCommons.ConfigRegistry:Register({
			name = addonName,
			displayName = "Splits",
			description = "Call out how far ahead or behind the pace a keystone is, at every boss",
			addonRef = PS,
			config = PS.Config,
			pages = PS.ConfigUI:GetPages(),
			order = 10,
		})
	end
end, {
	suppressAnnouncement = true
})
