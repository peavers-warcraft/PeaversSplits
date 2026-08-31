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

-- How long to keep asking the game which key this is before giving up, and how
-- often. Five seconds of asking costs nothing - the clock is already running by
-- then - and covers the gap comfortably; in practice both facts are there
-- within a frame or two.
local LEVEL_RETRY_DELAY = 0.25
local LEVEL_RETRY_LIMIT = 20

-- `Enum.CriteriaType.DefeatDungeonEncounter`. When a keystone objective carries
-- this type its `assetID` is the DungeonEncounterID - the SAME id the published
-- pool is keyed by, which is what makes the scenario objectives usable as a
-- boss-kill source at all rather than only as a progress display.
local CRITERIA_DEFEAT_ENCOUNTER = 165

-- A keystone has four or five objectives. Ten is well clear of that and costs
-- nothing: the scan is a handful of table reads against an API already in
-- memory, which is why Blizzard's own tracker and every M+ addon do the same.
local MAX_CRITERIA = 10

-- How long to keep trying to adopt a key that was already running when the
-- addon loaded. `PLAYER_ENTERING_WORLD` fires when the loading screen ends, and
-- the challenge-mode state and the world timer are pushed by the SERVER some
-- moments after that - so the first look almost always finds nothing, and a
-- one-shot attempt is a coin toss. Ten seconds of asking covers the gap without
-- ever being noticed; the addon that lands on the first attempt just stops.
local RECOVER_RETRY_DELAY = 0.5
local RECOVER_RETRY_LIMIT = 20

Run.active = false
Run.mapID = nil
Run.level = nil
Run.startedAt = nil
Run.recovered = false
-- Set when this client took its baseline from a peer instead of from its
-- own CHALLENGE_MODE_START. Nil means the clock is our own, either way.
Run.clockSource = nil
Run.killed = {}
Run.order = 0

-- Bumped every time a run starts or stops, and captured by the level retry so a
-- timer left over from the previous key cannot write a level into this one. A
-- reset-and-restart is exactly the sequence that produces two in flight at once.
Run.token = 0

-- The same idea for the recovery retry, which is a separate loop with a
-- separate lifetime: it runs while there is NO run, so it cannot lean on
-- `token`, which only moves when one starts or stops.
Run.recoverToken = 0

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

---Which dungeon this key is, in the ONE id space the published pool is keyed by.
---
---**`C_ChallengeMode.GetActiveChallengeMapID()` is the authority, never the
---`CHALLENGE_MODE_START` payload.** The event's argument is not the
---`mapChallengeModeID` the data addon is keyed by, so trusting it produced
---"No published pace for this dungeon yet" over Voidscar Arena +10 - a dungeon
---with 21 published runs at exactly that level.
---
---This is the same failure the keystone level had, through the other door, and
---it is worth naming why it survived a test suite: the offline harness fired
---`CHALLENGE_MODE_START` with the map id the test author believed it carried, so
---it only ever re-tested that belief. The game supplies the payload; the harness
---supplied the answer.
---
---There is deliberately no fallback to the payload. A momentarily-unreadable map
---id is covered by the retry below, whereas falling back to an id from a
---different space would silently pace the run against the wrong dungeon - a
---confident wrong answer, which is worse than a moment of silence.
---@return number|nil mapChallengeModeID
local function activeMapID()
	if not (C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID) then
		return nil
	end

	local mapID = C_ChallengeMode.GetActiveChallengeMapID()
	if type(mapID) ~= "number" or mapID < 1 then
		return nil
	end

	return mapID
end

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------

---The game's own challenge-mode timer, in seconds, or nil if it is not running.
---Found by TYPE rather than by index: `GetWorldElapsedTime(1)` happens to be the
---keystone timer most of the time, and "most of the time" is how an addon ends
---up reading a proving-ground clock in a dungeon.
---
---**`GetWorldElapsedTimers` returns the timer ids as multiple return values, not
---as a table**, so it has to be collected with `{ ... }`. Assigned to a single
---local it yields the first id - a number - and the `type(timers) ~= "table"`
---guard that used to stand here then rejected it every single time. That made
---this function return nil unconditionally, which is not a subtle degradation:
---`Run:Recover` gives up when it has no clock, so a `/reload` inside a keystone
---left the run untracked for the rest of the key, with the bar hidden and
---`/ps` reporting "no keystone running" while one plainly was.
---@return number|nil elapsed
local function worldElapsed()
	if type(GetWorldElapsedTimers) ~= "function" or type(GetWorldElapsedTime) ~= "function" then
		return nil
	end

	for _, timerID in ipairs({ GetWorldElapsedTimers() }) do
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
---
---`eventMapID` is the `CHALLENGE_MODE_START` payload and is deliberately NOT
---used to identify the dungeon - see `activeMapID`. It is kept only so the debug
---line can show what the event said next to what the API said, which is the
---evidence anyone re-opening this will want.
---@param eventMapID any the CHALLENGE_MODE_START payload, for logging only
function Run:Start(eventMapID)
	self.active = true
	self.mapID = activeMapID()
	self.level = activeLevel()
	self.startedAt = GetTime()
	self.recovered = false
	self.clockSource = nil
	self.killed = {}
	self.order = 0
	self.token = self.token + 1
	-- Orphans any recovery retry still in flight. The key started for real, so
	-- there is nothing left to adopt.
	self.recoverToken = self.recoverToken + 1

	PeaversCommons.Utils.Debug(PS, ("run started: map %s +%s (event payload: %s)")
		:format(tostring(self.mapID), tostring(self.level), tostring(eventMapID)))

	-- The clock is set above and unconditionally, because it is the one thing
	-- that must be exactly right. Only the ANNOUNCEMENT waits on the facts.
	if self.mapID and self.level then
		PS.Pace:OnRunStarted(self)
	else
		self:ResolveRun(self.token, 1)
	end

	PS.Sync:OnRunStarted()
	PS.PaceBar:Update()
end

---Keep asking which key this is, and announce only once BOTH facts are known.
---
---What is deferred is the sentence, never the clock: `startedAt` is already set,
---so a fact that arrives two frames late costs a moment of silence and nothing
---else. Announcing off the first read instead is what produced a confident
---"No pace published for ... +0 yet" at the start of a key that was fully
---covered - a plausible wrong answer, which is worse than saying nothing.
---
---The map id is resolved here for the same reason and in the same loop. It used
---to be taken from the event payload and never re-read, which is how a covered
---dungeon came out as "No published pace for this dungeon yet".
---@param token number the run this retry belongs to
---@param attempt number
function Run:ResolveRun(token, attempt)
	if not self.active or self.token ~= token then
		return
	end

	self.mapID = self.mapID or activeMapID()
	self.level = self.level or activeLevel()

	if self.mapID and self.level then
		PeaversCommons.Utils.Debug(PS, ("run resolved to map %d +%d on attempt %d")
			:format(self.mapID, self.level, attempt))
		PS.Pace:OnRunStarted(self)

		-- Say so again now the key can be named. The claim sent before this point
		-- carried a zero map id, which every peer correctly threw away - so without
		-- this the group stays unsynced until the next heartbeat, for no reason
		-- other than the client having been slow to publish the keystone.
		PS.Sync:Broadcast()
		PS.PaceBar:Update()
		return
	end

	if attempt >= LEVEL_RETRY_LIMIT then
		-- Out of tries. Say which fact was missing - never report the absence of a
		-- pool nobody managed to look for.
		PeaversCommons.Utils.Debug(PS, ("gave up reading the key: map %s +%s")
			:format(tostring(self.mapID), tostring(self.level)))
		PS.Pace:OnRunUnreadable(self)
		return
	end

	C_Timer.After(LEVEL_RETRY_DELAY, function()
		self:ResolveRun(token, attempt + 1)
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
	self.mapID = activeMapID()
	self.level = activeLevel()
	self.token = self.token + 1
	-- No start instant, so GetElapsed falls through to the game's timer. Note we
	-- deliberately do NOT synthesise `startedAt = GetTime() - elapsed`: that would
	-- look like a precise clock and quietly bake in whatever the game's timer
	-- counts, which is the ambiguity this whole file exists to avoid.
	self.startedAt = nil
	self.recovered = true
	self.clockSource = nil
	self.killed = {}

	-- Filled in by the objective scan below, which knows exactly which bosses are
	-- already down - so unlike the clock, the kill list survives a reload intact
	-- and the ordinal keeps counting from the right number.
	self.order = 0

	PeaversCommons.Utils.Debug(PS, ("run recovered at %.1fs: map %s +%s")
		:format(elapsed, tostring(self.mapID), tostring(self.level)))

	-- Same rule as Start: a fact that is not readable yet is not a fact, and an
	-- unreadable key must not be announced as an uncovered one.
	if self.mapID and self.level then
		PS.Pace:OnRunStarted(self)
	else
		self:ResolveRun(self.token, 1)
	end

	-- Adopt the bosses that died before we loaded, WITHOUT announcing them. The
	-- group killed those minutes ago and does not need them called out again;
	-- what this buys is a correct ordinal and a correct "N bosses down".
	self:ScanObjectives(false)

	-- Announce ourselves to the group. This is the moment the sync is FOR: a
	-- client that reloaded holds the weaker clock, and anybody who did not
	-- reload can hand back the exact one.
	PS.Sync:OnRunStarted()

	return true
end

---Try to adopt an already-running key, and keep trying for a short while.
---
---This is what `PLAYER_ENTERING_WORLD` and `WORLD_STATE_TIMER_START` both call,
---because neither one on its own is reliably the moment the facts exist.
---`Recover` needs three things from the server - the challenge-mode flag, the
---world timer, and the keystone - and after a `/reload` they arrive over the
---following second or so, in no guaranteed order and all of them after the
---loading screen ends. A single look at world entry is therefore a race that
---the addon usually loses, and losing it silently costs the rest of the key.
---
---Idempotent on purpose: it gives up the moment a run is active, so being
---called from two events, or from the same event twice, adopts one run.
function Run:BeginRecovery()
	self.recoverToken = self.recoverToken + 1
	self:TryRecover(self.recoverToken, 1)
end

---@param token number the recovery attempt this retry belongs to
---@param attempt number
function Run:TryRecover(token, attempt)
	-- A run started, stopped, or was adopted by another attempt while this one
	-- was waiting. Either way there is nothing here to do.
	if self.active or self.recoverToken ~= token then
		return
	end

	if self:Recover() then
		return
	end

	if attempt >= RECOVER_RETRY_LIMIT then
		-- Not an error. The overwhelmingly common case is world entry with no
		-- keystone anywhere in sight, which is every loading screen in the game.
		PeaversCommons.Utils.Debug(PS, "no keystone to recover")
		return
	end

	C_Timer.After(RECOVER_RETRY_DELAY, function()
		self:TryRecover(token, attempt + 1)
	end)
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
	self.clockSource = nil
	self.killed = {}
	self.order = 0
	-- Orphans any level retry still in flight, so it cannot announce into the
	-- next run - or into no run at all. The recovery retry is orphaned for the
	-- same reason: stopping is a decision, and a retry from before it must not
	-- quietly undo one.
	self.token = self.token + 1
	self.recoverToken = self.recoverToken + 1

	PS.Sync:OnRunStopped()
	PS.PaceBar:Update()
end

--------------------------------------------------------------------------------
-- Where a boss kill actually comes from
--
-- **Not `ENCOUNTER_END`, or not only it.** That event is the obvious source and
-- it is not a dependable one inside a keystone: this addon shipped reading it
-- alone, and the result was a run that announced its finish line correctly and
-- said nothing whatsoever at any of the bosses on the way there.
--
-- The dependable source is the keystone's own objective list. A boss is an
-- objective with `criteriaType` 165, its `assetID` IS the DungeonEncounterID,
-- and `completed` is the game's own answer to whether it is down - the same
-- state the player is reading off their objective tracker. WarpDeplete takes
-- boss times this way and uses ENCOUNTER_END for nothing but resetting its pull
-- tracker; RaiderIO watches the same criteria updates. Following them is not
-- cargo-culting: the objective list is what the server actually maintains for a
-- keystone, and the encounter event is not.
--
-- `ENCOUNTER_END` is kept as a second door, because when it does fire it fires
-- at the instant of the kill. Both doors land in `RecordKill`, which dedupes on
-- the encounter id, so whichever arrives first wins and the other is ignored.
--------------------------------------------------------------------------------

---Record a boss dying, and hand the split to Pace.
---
---Guarded against being told twice about the same boss - by two events, or by
---one event twice - which would otherwise double-post into somebody's party
---chat and read as the group having killed it twice.
---@param encounterID number DungeonEncounterID
---@param encounterName string|nil the boss's name, as this client spells it
---@param elapsed number|nil seconds into the run when it died
---@param announce boolean whether to say so, or only to record it
---@return boolean recorded
function Run:RecordKill(encounterID, encounterName, elapsed, announce)
	if type(encounterID) ~= "number" or self.killed[encounterID] then
		return false
	end

	if not elapsed or elapsed < 0 then
		PeaversCommons.Utils.Debug(PS, "no clock available - cannot split")
		return false
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

	if announce then
		PS.Pace:OnBossKilled(self, encounterID, encounterName, elapsed, self.order)
	end

	PS.PaceBar:Update()
	return true
end

---Read the keystone's objective list and record every boss that has gone down.
---@param announce boolean false to adopt the current state silently, which is
---what a recovered run needs: the bosses killed before the reload are already
---in the objective list, and calling them out now would post a burst of stale
---splits into party chat minutes after the group killed them.
function Run:ScanObjectives(announce)
	if not self.active then
		return
	end

	if not (C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo) then
		return
	end

	local elapsed = self:GetElapsed()
	if not elapsed then
		return
	end

	for index = 1, MAX_CRITERIA do
		local ok, info = pcall(C_ScenarioInfo.GetCriteriaInfo, index)

		if ok and type(info) == "table"
			and info.criteriaType == CRITERIA_DEFEAT_ENCOUNTER
			and info.completed
			and not self.killed[info.assetID] then

			-- `elapsed` on a completed criterion is how long ago it completed, so
			-- this is the split ITSELF rather than the moment we happened to look.
			-- That matters on the scan after a reload, where "now" would be minutes
			-- wrong, and it is no worse than ENCOUNTER_END even live.
			local at = elapsed - (info.elapsed or 0)

			-- A figure outside the run cannot be a split in it. Falling back to now
			-- keeps the boss recorded rather than dropping it over a bad offset.
			if at < 0 or at > elapsed then
				at = elapsed
			end

			self:RecordKill(info.assetID, info.description, at, announce)
		end
	end
end

---`ENCOUNTER_END`, which fires at the instant of the kill when it fires at all.
---
---Only a kill counts. The event also fires on a wipe, with `success` 0, and a
---wipe has no split - the boss has not been reached yet, it has been failed at.
---Counting one would put a time against a boss that is still alive.
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

	self:RecordKill(encounterID, encounterName, self:GetElapsed(), true)
end

---The objective list changed. The usual cause is the enemy-forces count ticking
---over, which the scan ignores; occasionally it is a boss dying, which it does not.
function Run:OnObjectivesChanged()
	self:ScanObjectives(true)
end
