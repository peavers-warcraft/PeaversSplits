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
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")

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
			PS.Run:Recover()
		end
	end
end
