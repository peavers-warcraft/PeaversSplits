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

-- How long to keep asking the game for the keystone level before giving up, and
-- how often. Five seconds of asking costs nothing - the clock is already
-- running by then - and covers the gap comfortably; in practice the level is
-- there within a frame or two.
local LEVEL_RETRY_DELAY = 0.25
local LEVEL_RETRY_LIMIT = 20

Run.active = false
Run.mapID = nil
Run.level = nil
Run.startedAt = nil
Run.recovered = false
Run.killed = {}
Run.order = 0

-- Bumped every time a run starts or stops, and captured by the level retry so a
-- timer left over from the previous key cannot write a level into this one. A
-- reset-and-restart is exactly the sequence that produces two in flight at once.
Run.token = 0

--------------------------------------------------------------------------------
-- The keystone level, which is not readable the instant the run starts
--------------------------------------------------------------------------------

---The active keystone's level, or nil when the game has not published it yet.
---
---**`C_ChallengeMode.GetActiveKeystoneInfo` answers `0`, not `nil`, before the
---client has the run's keystone**, and `0` is TRUE in Lua - so the obvious
---`GetActiveKeystoneInfo() or nil` keeps the zero rather than rejecting it, and
---every lookup downstream then asks the data addon for a "+0" pool that cannot
---exist. That is not a miss the player can interpret: it comes out as the
---sentence "No pace published for Murder Row +0 yet" over a dungeon with 54
---published runs at the level actually being played.
---
---So a level is only a level here if it is a number and at least 1. Blizzard's
---own tracker does the same thing by a different route - it does not read the
---keystone until the challenge-mode world timer exists, and guards the active
---map id even then (`ScenarioTimerMixin:CheckTimers`).
---@return number|nil level
local function activeLevel()
	if not (C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo) then
		return nil
	end

	local level = C_ChallengeMode.GetActiveKeystoneInfo()
	if type(level) ~= "number" or level < 1 then
		return nil
	end

	return level
end

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
	self.active = true
	self.mapID = mapID
	self.level = activeLevel()
	self.startedAt = GetTime()
	self.recovered = false
	self.killed = {}
	self.order = 0
	self.token = self.token + 1

	PeaversCommons.Utils.Debug(PS, ("run started: map %s +%s")
		:format(tostring(mapID), tostring(self.level)))

	-- The clock is set above and unconditionally, because it is the one thing
	-- that must be exactly right. Only the ANNOUNCEMENT waits on the level.
	if self.level then
		PS.Pace:OnRunStarted(self)
	else
		self:ResolveLevel(self.token, 1)
	end

	PS.PaceBar:Update()
end

---Keep asking for the keystone level, and announce only once it is known.
---
---What is deferred is the sentence, never the clock: `startedAt` is already set,
---so a level that arrives two frames late costs a moment of silence and nothing
---else. Announcing off the first read instead is what produced a confident
---"No pace published for ... +0 yet" at the start of a key that was fully
---covered - a plausible wrong answer, which is worse than saying nothing.
---@param token number the run this retry belongs to
---@param attempt number
function Run:ResolveLevel(token, attempt)
	if not self.active or self.token ~= token or self.level then
		return
	end

	local level = activeLevel()
	if level then
		self.level = level
		PeaversCommons.Utils.Debug(PS, ("keystone level resolved to +%d on attempt %d")
			:format(level, attempt))
		PS.Pace:OnRunStarted(self)
		PS.PaceBar:Update()
		return
	end

	if attempt >= LEVEL_RETRY_LIMIT then
		-- Out of tries. Say what is actually true - the level could not be read -
		-- rather than reporting the absence of a pool nobody looked for.
		PeaversCommons.Utils.Debug(PS, "keystone level never became readable")
		PS.Pace:OnLevelUnknown(self)
		return
	end

	C_Timer.After(LEVEL_RETRY_DELAY, function()
		self:ResolveLevel(token, attempt + 1)
	end)
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
	self.level = activeLevel()
	self.token = self.token + 1
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

	-- Same rule as Start: a level that is not readable yet is not a level, and an
	-- unreadable one must not be announced as an uncovered one.
	if self.level then
		PS.Pace:OnRunStarted(self)
	else
		self:ResolveLevel(self.token, 1)
	end

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
	-- Orphans any level retry still in flight, so it cannot announce into the
	-- next run - or into no run at all.
	self.token = self.token + 1

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

	-- Last chance to learn the level. If the retries above ran out - or the run
	-- was recovered before the client had the keystone - a boss dying is proof
	-- the run is well underway, so ask once more rather than spending the rest of
	-- the key comparing against nothing.
	if not self.level then
		self.level = activeLevel()
	end

	PS.Pace:OnBossKilled(self, encounterID, encounterName, elapsed, self.order)
	PS.PaceBar:Update()
end
