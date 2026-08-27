--------------------------------------------------------------------------------
-- Run - the keystone currently being run, and its clock
--
-- One job: know how many seconds into the run we are, and notice each boss
-- dying. Everything about what that means lives in Pace.
--
-- ## The clock, which is the one thing that must be exactly right
--
-- A published split is measured from `CHALLENGE_MODE_START` to `ENCOUNTER_END`
-- in the combat log - **real elapsed seconds**, nothing added and nothing taken
-- away. So this has to measure the same thing, and the obvious candidate does
-- not obviously do it.
--
-- The in-game keystone timer is not a plain stopwatch: a death costs the group
-- time against the dungeon's par. Whether `GetWorldElapsedTime` reports raw
-- elapsed or the penalised figure is not something this addon should have to be
-- right about by assumption, because being wrong is invisible - the delta simply
-- drifts, always in the same direction, by five seconds per death, and reads as
-- a group that got slower.
--
-- So the primary clock is our own: `GetTime()` at `CHALLENGE_MODE_START`,
-- subtracted at each kill. `GetTime()` is a monotonic seconds counter, it is
-- exactly "real elapsed", and it is definitionally the same quantity the
-- benchmark was built from.
--
-- `GetWorldElapsedTime` is kept as the RECOVERY path only, for the case the
-- primary cannot cover: the addon loading into a key already in progress, which
-- is what a `/reload` mid-dungeon does. A run recovered that way is marked, and
-- Pace says so rather than quietly publishing a number it is less sure of.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons

local Run = {}
PS.Run = Run

-- Enum.WorldElapsedTimerTypes.ChallengeMode. Read through the enum where it
-- exists and fall back to the literal, because an addon that errors on a
-- missing enum during a keystone is worse than one that hardcodes a 1.
local CHALLENGE_MODE_TIMER =
	(Enum and Enum.WorldElapsedTimerTypes and Enum.WorldElapsedTimerTypes.ChallengeMode) or 1

Run.active = false
Run.mapID = nil
Run.level = nil
Run.startedAt = nil
Run.recovered = false
Run.killed = {}
Run.order = 0

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------

---The game's own challenge-mode timer, in seconds, or nil if it is not running.
---Found by TYPE rather than by index: `GetWorldElapsedTime(1)` happens to be the
---keystone timer most of the time, and "most of the time" is how an addon ends
---up reading a proving-ground clock in a dungeon.
---@return number|nil elapsed
local function worldElapsed()
	if type(GetWorldElapsedTimers) ~= "function" or type(GetWorldElapsedTime) ~= "function" then
		return nil
	end

	local timers = GetWorldElapsedTimers()
	if type(timers) ~= "table" then
		return nil
	end

	for _, timerID in ipairs(timers) do
		local ok, _, elapsed, timerType = pcall(GetWorldElapsedTime, timerID)
		if ok and timerType == CHALLENGE_MODE_TIMER and type(elapsed) == "number" then
			return elapsed
		end
	end

	return nil
end

---Seconds into the run, or nil when no run is being tracked.
---@return number|nil elapsed
function Run:GetElapsed()
	if not self.active then
		return nil
	end

	if self.startedAt then
		return GetTime() - self.startedAt
	end

	-- Recovered run: we never saw the start, so the game's timer is all there is.
	return worldElapsed()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---Begin tracking a keystone that started just now.
---@param mapID number mapChallengeModeID from CHALLENGE_MODE_START
function Run:Start(mapID)
	local level = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo
		and C_ChallengeMode.GetActiveKeystoneInfo() or nil

	self.active = true
	self.mapID = mapID
	self.level = level
	self.startedAt = GetTime()
	self.recovered = false
	self.killed = {}
	self.order = 0

	PeaversCommons.Utils.Debug(PS, ("run started: map %s +%s"):format(tostring(mapID), tostring(level)))
	PS.Pace:OnRunStarted(self)
	PS.PaceBar:Update()
end

---Adopt a keystone that was already running when this addon loaded.
---
---The window this covers is a `/reload` inside a dungeon, which is common
---enough that being silent for the rest of the key would be the wrong answer.
---What is given up is the exact start instant, so the run is marked `recovered`
---and every figure derived from it carries that caveat outward.
function Run:Recover()
	if not (C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
		and C_ChallengeMode.IsChallengeModeActive()) then
		return false
	end

	local elapsed = worldElapsed()
	if not elapsed then
		return false
	end

	self.active = true
	self.mapID = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID() or nil
	self.level = C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo() or nil
	-- No start instant, so GetElapsed falls through to the game's timer. Note we
	-- deliberately do NOT synthesise `startedAt = GetTime() - elapsed`: that would
	-- look like a precise clock and quietly bake in whatever the game's timer
	-- counts, which is the ambiguity this whole file exists to avoid.
	self.startedAt = nil
	self.recovered = true
	self.killed = {}

	-- Bosses already down before we loaded are unknown, so the ordinal cannot be
	-- trusted either. Zero means "we do not know how many came before".
	self.order = 0

	PeaversCommons.Utils.Debug(PS, ("run recovered at %.1fs: map %s +%s")
		:format(elapsed, tostring(self.mapID), tostring(self.level)))
	PS.Pace:OnRunStarted(self)
	return true
end

---Stop tracking. Called on completion, on leaving the instance, and on reset.
function Run:Stop()
	if not self.active then
		return
	end

	self.active = false
	self.mapID = nil
	self.level = nil
	self.startedAt = nil
	self.recovered = false
	self.killed = {}
	self.order = 0

	PS.PaceBar:Update()
end

--------------------------------------------------------------------------------
-- Boss kills
--------------------------------------------------------------------------------

---Record a boss dying, and hand the split to Pace.
---
---Only a kill counts. `ENCOUNTER_END` also fires on a wipe, with `success` 0,
---and a wipe has no split - the boss has not been reached yet, it has been
---failed at. Counting one would put a time against a boss that is still alive.
---
---Guarded against firing twice for the same boss in one run, which costs
---nothing to defend against and would otherwise double-post into somebody's
---party chat.
---@param encounterID number DungeonEncounterID
---@param encounterName string the boss's name, as this client spells it
---@param success boolean|number whether the boss died
function Run:OnEncounterEnd(encounterID, encounterName, success)
	if not self.active then
		return
	end

	-- ENCOUNTER_END hands `success` through as 1/0 rather than a boolean.
	local killed = success == true or success == 1
	if not killed then
		PeaversCommons.Utils.Debug(PS, ("wipe on %s - no split"):format(tostring(encounterID)))
		return
	end

	if self.killed[encounterID] then
		PeaversCommons.Utils.Debug(PS, ("duplicate ENCOUNTER_END for %s - ignored"):format(tostring(encounterID)))
		return
	end

	local elapsed = self:GetElapsed()
	if not elapsed then
		PeaversCommons.Utils.Debug(PS, "no clock available - cannot split")
		return
	end

	self.killed[encounterID] = elapsed
	self.order = self.order + 1

	PS.Pace:OnBossKilled(self, encounterID, encounterName, elapsed, self.order)
	PS.PaceBar:Update()
end
