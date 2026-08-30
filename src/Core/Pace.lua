--------------------------------------------------------------------------------
-- Pace - what a split means, held against the published pool
--
-- Run knows the clock. This knows whether the number is worth saying, and it is
-- the only place allowed to decide that.
--
-- ## The rule this file exists to keep
--
-- **A level with no pool gets no comparison.** Not the nearest level, not a
-- blend, not "close enough". Enemy health scales per keystone level, so a +14
-- measured against the +12 pool is told it is behind a pace nobody at +14 ever
-- set - a plausible number, wrong in one direction, with nothing about it
-- looking wrong. The published data refuses to pool across levels for exactly
-- this reason and this addon must not undo that on the client.
--
-- What it does instead is say what IS covered. "No pace for +14 in Murder Row
-- yet, the highest published is +12" is true, useful, and makes no comparison.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons

local Pace = {}
PS.Pace = Pace

---The data addon's API, or nil when it is not installed.
---Resolved per call rather than cached at load: the TOC dependency normally
---guarantees it, but a Curse install can desync, and a cached nil would outlive
---the fix.
---@return table|nil api
local function api()
	local data = _G.PeaversSplitsData
	if type(data) ~= "table" or type(data.API) ~= "table" then
		return nil
	end
	return data.API
end

PS.GetDataAPI = api

---Whether the data addon is present and answering.
---@return boolean
function PS.HasData()
	local a = api()
	return a ~= nil and type(a.GetSplit) == "function"
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

---`m:ss` - the clock a dungeon is talked about on.
---@param seconds number
---@return string
function Pace.Clock(seconds)
	local total = math.max(0, math.floor(seconds + 0.5))
	return ("%d:%02d"):format(math.floor(total / 60), total % 60)
end

---Turns a delta into the words that go in front of a reader.
---
---Returns the whole phrase rather than a bare number, because the level case is
---not a number at all: "0:00 vs pace" is a sentence nobody says, and an earlier
---cut of this returned the string "level" for the caller to splice, which
---produced "down at 7:46, level vs pace". One function owning the phrase is what
---stops that class of seam.
---
---The sign is always written on a real difference. Without it the figure is a
---duration, and "1:20" and "+1:20" are opposite claims about the same run. The
---minus is a plain ASCII hyphen rather than a typographic one: this goes into
---party chat, where a stray multibyte character becomes somebody else's client's
---problem.
---@param delta number seconds, negative when ahead
---@return string phrase
function Pace.Delta(delta)
	-- Inside a second either way is not a difference. Saying "+0:00" would invite
	-- a reader to look for a gap that the data cannot resolve.
	if delta >= -0.5 and delta <= 0.5 then
		return "on pace"
	end

	local sign = delta < 0 and "-" or "+"
	return ("%s%s vs pace"):format(sign, Pace.Clock(math.abs(delta)))
end

--------------------------------------------------------------------------------
-- Run lifecycle
--------------------------------------------------------------------------------

---Say, once, what this run is being compared against - or that nothing is.
---
---Being silent on an uncovered level is the wrong answer: the addon looks
---broken for the whole key, and the player has no way to tell "no data" from
---"not installed" from "not working".
---@param run table
function Pace:OnRunStarted(run)
	if not PS.Config.announceStart then
		return
	end

	local a = api()
	if not a then
		PS.Announcer:Local("PeaversSplitsData is missing - no pace to compare against.")
		return
	end

	local dungeon = a.GetDungeonName(run.mapID)
	if not dungeon then
		PS.Announcer:Local(("No published pace for this dungeon yet (map %s).")
			:format(tostring(run.mapID)))
		return
	end

	-- Run only calls this with a level in hand; the guard is here because the
	-- alternative failure is silent and confident. Without a level the only
	-- honest sentences below are lies - "no pace published for +0" names a pool
	-- that could never exist, on a key whose real level may be fully covered.
	if not run.level then
		self:OnLevelUnknown(run)
		return
	end

	if a.GetBosses(run.mapID, run.level) then
		local suffix = run.recovered and " Reloaded mid-run, so the clock is the game's own." or ""
		PS.Announcer:Local(("Pacing %s +%d against the published %s pool.%s")
			:format(dungeon, run.level or 0, tostring(a.GetPartition() or "?"), suffix))
		return
	end

	-- Covered dungeon, uncovered level. Name what exists; compare with none of it.
	local levels = a.GetLevels(run.mapID)
	if levels and #levels > 0 then
		PS.Announcer:Local(("No pace published for %s +%d yet. Levels with data: %s.")
			:format(dungeon, run.level, table.concat(levels, ", ")))
	else
		PS.Announcer:Local(("No pace published for %s yet."):format(dungeon))
	end
end

---The keystone level never became readable, so nothing was compared.
---
---This is a different sentence from "no pace published", and keeping them apart
---is the whole point: one is a fact about the published pool, the other is a
---fault in this addon's reading of the game. Collapsing them is what let a
---covered +10 be reported as an uncovered key.
---@param run table
function Pace:OnLevelUnknown(run)
	if not PS.Config.announceStart then
		return
	end

	local a = api()
	local dungeon = (a and a.GetDungeonName(run.mapID)) or ("map " .. tostring(run.mapID))

	PS.Announcer:Local(("Could not read the keystone level for %s, so splits will be called out "
		.. "with nothing to compare against. /reload fixes it."):format(dungeon))
end

---A boss died. Work out whether there is anything to say, and say it.
---`encounterName` comes from the event rather than from the benchmark, and that
---is deliberate: the published name is English (it is the journal's), while the
---event hands over whatever this client calls the boss. This goes into party
---chat, so the player's own language wins. The benchmark's name is the fallback
---for the case the event gives us nothing.
---@param run table
---@param encounterID number
---@param encounterName string|nil the boss's name as this client spells it
---@param elapsed number seconds from the start of the run
---@param ordinal number which boss of this run this was, 1-based
function Pace:OnBossKilled(run, encounterID, encounterName, elapsed, ordinal)
	local a = api()
	local benchmark = a and a.GetSplit(run.mapID, run.level, encounterID) or nil
	local name = encounterName
		or (benchmark and benchmark.name)
		or ("boss %s"):format(tostring(encounterID))

	-- No pool: still worth stating the split. It is a fact about this run and
	-- does not depend on anybody else having done the dungeon - and a player who
	-- hears their own splits called out has something even on an uncovered level.
	if not benchmark then
		PS.Announcer:Split(("%s down at %s."):format(name, Pace.Clock(elapsed)))
		return
	end

	local delta = elapsed - benchmark.split
	local parts = {
		("%s down at %s"):format(name, Pace.Clock(elapsed)),
		Pace.Delta(delta),
	}

	-- The spread is what says whether the delta means anything. Inside the
	-- middle half of the pool is ordinary, and saying so stops a reader treating
	-- twenty seconds on a four-minute spread as a finding.
	if PS.Config.showSpread and benchmark.fast and benchmark.slow then
		if elapsed >= benchmark.fast and elapsed <= benchmark.slow then
			parts[#parts + 1] = "inside the usual range"
		end
	end

	if PS.Config.showSampleSize and benchmark.runs then
		parts[#parts + 1] = ("%d runs"):format(benchmark.runs)
	end

	PS.Announcer:Split(table.concat(parts, ", ") .. ".")
	PeaversCommons.Utils.Debug(PS, ("boss %d (%s): %.1fs vs %.1fs")
		:format(ordinal, tostring(encounterID), elapsed, benchmark.split))
end

---The key finished. One line on where it ended up against the last boss's pace.
---@param run table
function Pace:OnRunFinished(run)
	if not PS.Config.announceFinish then
		return
	end

	local a = api()
	if not a then
		return
	end

	-- The last boss killed is the honest place to sum up: it is the last point
	-- the run can be compared at, and the dungeon's own completion time is a
	-- different number (it carries the death penalty, which no published split
	-- does).
	local lastID, lastAt
	for encounterID, at in pairs(run.killed) do
		if not lastAt or at > lastAt then
			lastID, lastAt = encounterID, at
		end
	end

	if not lastID then
		return
	end

	local benchmark = a.GetSplit(run.mapID, run.level, lastID)
	if not benchmark then
		return
	end

	PS.Announcer:Split(("Key done. %s at the last boss.")
		:format(Pace.Delta(lastAt - benchmark.split)))
end
