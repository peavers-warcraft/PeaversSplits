--------------------------------------------------------------------------------
-- Events - the game's side of the conversation
--
-- Four events and nothing else. Kept apart from Run so that Run is a plain
-- object that can be driven from a test as easily as from a dungeon.
--
-- ## Why PLAYER_ENTERING_WORLD is here
--
-- `CHALLENGE_MODE_START` fires once, when the key is activated. An addon that
-- only listens for it is silent for the rest of any run during which the player
-- reloaded - which is a normal thing to do, and the point at which someone is
-- most likely to be fiddling with addons. So every world entry asks the game
-- whether a keystone is already running and adopts it if so.
--
-- ## Why WORLD_STATE_TIMER_START is here too
--
-- Because `PLAYER_ENTERING_WORLD` is too early to be trusted on its own. It
-- fires when the loading screen ends; the keystone timer arrives afterwards,
-- pushed by the server, and `WORLD_STATE_TIMER_START` is the event that says so.
-- Asking at both moments - and, via `Run:BeginRecovery`, for a few seconds
-- after either - is what Blizzard's own tracker and every other keystone addon
-- do, and for the same reason. Adopting twice is not a risk: recovery is
-- idempotent and stops dead once a run is active.
--
-- ## Why CHALLENGE_MODE_RESET stops the run
--
-- The group can reset a key and start again from the top. Without this the
-- clock would keep counting from the first attempt and every split after the
-- reset would be minutes late, which is the shape of bug that reads as "the
-- addon is wrong about my dungeon" rather than as a missing event.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons

local Events = {}
PS.Events = Events

local frame

function Events:Initialize()
	if frame then
		return
	end

	frame = CreateFrame("Frame")
	frame:RegisterEvent("CHALLENGE_MODE_START")
	frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
	frame:RegisterEvent("CHALLENGE_MODE_RESET")
	frame:RegisterEvent("ENCOUNTER_END")
	frame:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("WORLD_STATE_TIMER_START")
	frame:RegisterEvent("CHAT_MSG_ADDON")

	frame:SetScript("OnEvent", function(_, event, ...)
		Events:Handle(event, ...)
	end)

	PeaversCommons.Utils.Debug(PS, "events registered")
end

---@param event string
function Events:Handle(event, ...)
	if event == "CHALLENGE_MODE_START" then
		local mapID = ...
		PS.Announcer:Reset()
		PS.Run:Start(mapID)

	elseif event == "SCENARIO_CRITERIA_UPDATE" then
		-- The keystone's own objective list changed. This is the PRIMARY boss-kill
		-- source, not a backup - see the section header in Run.lua. It fires often
		-- and is nearly always the enemy-forces count moving, which the scan skips.
		PS.Run:OnObjectivesChanged()

	elseif event == "ENCOUNTER_END" then
		-- encounterID, encounterName, difficultyID, groupSize, success
		local encounterID, encounterName, _, _, success = ...
		PS.Run:OnEncounterEnd(encounterID, encounterName, success)

	elseif event == "CHALLENGE_MODE_COMPLETED" then
		-- Summarise before stopping: OnRunFinished reads the run's own kill list.
		PS.Pace:OnRunFinished(PS.Run)
		PS.Run:Stop()

	elseif event == "CHALLENGE_MODE_RESET" then
		PS.Run:Stop()

	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Adopt a key that was already running, and let go of one that is not.
		-- Both directions matter: without the second, walking out of a finished
		-- dungeon leaves a run "active" and the next ENCOUNTER_END anywhere at all
		-- would be measured against a dead clock.
		if PS.Run.active and not (C_ChallengeMode.IsChallengeModeActive
			and C_ChallengeMode.IsChallengeModeActive()) then
			PS.Run:Stop()
		elseif not PS.Run.active then
			PS.Run:BeginRecovery()
		end

	elseif event == "CHAT_MSG_ADDON" then
		-- prefix, text, channel, sender
		PS.Sync:OnMessage(...)

	elseif event == "WORLD_STATE_TIMER_START" then
		-- The keystone clock just appeared. If that is because a key was already
		-- running when we loaded, this is the earliest honest moment to adopt it.
		-- A no-op during a normal `CHALLENGE_MODE_START`, where the run is already
		-- active and being timed from our own clock.
		if not PS.Run.active then
			PS.Run:BeginRecovery()
		end
	end
end
