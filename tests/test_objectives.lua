--------------------------------------------------------------------------------
-- Where a boss kill comes from.
--
-- The bug these exist for: a key ran, the finish line was announced correctly,
-- and not one of the bosses on the way there was called out. The addon read
-- boss kills from `ENCOUNTER_END` alone, which is the obvious source and not a
-- dependable one inside a keystone.
--
-- So the rule being held here is deliberately harsh: **every test in this file
-- that expects a split fires NO `ENCOUNTER_END` at all.** If the addon ever
-- goes back to depending on that event, this whole file goes red rather than
-- quietly passing on the second source the way the old suite did.
--
-- What the game actually maintains for a keystone is the objective list. A boss
-- is a criterion with `criteriaType` 165 whose `assetID` is the
-- DungeonEncounterID - the same id the published pool is keyed by.
--------------------------------------------------------------------------------

local harness = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".")
	.. "/harness.lua")

local MURDER_ROW = 587
local CHALLENGE_MODE_TIMER = 1

local failures = 0
local checks = 0

local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures = failures + 1
		io.write(("  FAIL  %s\n"):format(label))
	else
		io.write(("  ok    %s\n"):format(label))
	end
end

local function case(name, fn)
	io.write(name .. "\n")
	fn()
end

---Start a key with the addon watching, in a group, with nothing down yet.
local function inKey(game, PS)
	game.inGroup = true
	game.activeMapID = MURDER_ROW
	game.keystoneLevel = 10
	game.challengeActive = true
	game.criteria = { harness.forcesCriterion(0) }
	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)
end

local function saidInParty(game, needle)
	for _, sent in ipairs(game.sent) do
		if sent.channel == "PARTY" and sent.message:find(needle, 1, true) then
			return sent.message
		end
	end
	return nil
end

local function partyCount(game)
	local count = 0
	for _, sent in ipairs(game.sent) do
		if sent.channel == "PARTY" then
			count = count + 1
		end
	end
	return count
end

local function killCount(run)
	local count = 0
	for _ in pairs(run.killed) do
		count = count + 1
	end
	return count
end

--------------------------------------------------------------------------------

case("the real published data names a boss we can key on", function()
	harness.load()
	local bosses = _G.PeaversSplitsData.API.GetBosses(MURDER_ROW, 10)
	check(bosses ~= nil, "the +10 pool is there")

	local anyID
	for encounterID in pairs(bosses or {}) do
		anyID = anyID or encounterID
	end
	check(type(anyID) == "number",
		"and is keyed by DungeonEncounterID, got " .. type(anyID))
end)

case("a boss called out with no ENCOUNTER_END anywhere", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(312)

	-- The objective list flips. This is the ONLY thing the game tells us.
	local bosses = _G.PeaversSplitsData.API.GetBosses(MURDER_ROW, 10)
	local encounterID = next(bosses)
	game.criteria = {
		harness.forcesCriterion(41),
		harness.bossCriterion(encounterID, "The First One", 0),
	}
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(killCount(PS.Run) == 1, "the kill is recorded")
	check(PS.Run.order == 1, "as the first boss, got " .. tostring(PS.Run.order))

	local line = saidInParty(game, "down at")
	check(line ~= nil, "and called out to the party")
	check(line and line:find("5:12", 1, true) ~= nil,
		"at the right time, got: " .. tostring(line))
end)

case("the split is when the boss died, not when we noticed", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(400)

	-- The criterion says it completed 88 seconds ago. Reading "now" instead
	-- would put the boss a minute and a half late for the rest of the run.
	game.criteria = {
		harness.bossCriterion(12345, "Late Notice", 88),
	}
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(PS.Run.killed[12345] == 312,
		"312s, not 400s - got " .. tostring(PS.Run.killed[12345]))
end)

case("an implausible offset falls back to now rather than dropping the boss", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(120)

	-- Longer ago than the run has existed. Believing it would post a negative
	-- split; dropping it would lose the boss entirely.
	game.criteria = { harness.bossCriterion(999, "Nonsense", 9999) }
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(PS.Run.killed[999] == 120,
		"recorded at now, got " .. tostring(PS.Run.killed[999]))
end)

case("the enemy-forces bar is not a boss", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(60)

	-- SCENARIO_CRITERIA_UPDATE fires constantly for this. None of them are kills.
	for percent = 10, 100, 10 do
		game.criteria = { harness.forcesCriterion(percent) }
		PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")
	end

	check(killCount(PS.Run) == 0, "nothing recorded, got " .. killCount(PS.Run))
	check(partyCount(game) == 0, "and nothing said, got " .. partyCount(game))
end)

case("a boss is called out once, however many updates arrive", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(200)

	game.criteria = { harness.bossCriterion(2900, "Grimbill", 0) }
	for _ = 1, 5 do
		PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")
	end

	check(partyCount(game) == 1, "one line, got " .. partyCount(game))
	check(PS.Run.order == 1, "and one ordinal, got " .. tostring(PS.Run.order))
end)

case("the two sources do not double up on each other", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(150)

	-- ENCOUNTER_END fires AND the objective flips, which is what happens when
	-- the event works. The group must still hear about the boss exactly once.
	PS.Events:Handle("ENCOUNTER_END", 2900, "Grimbill", 8, 5, 1)
	game.criteria = { harness.bossCriterion(2900, "Grimbill", 0) }
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(partyCount(game) == 1, "one line, got " .. partyCount(game))
	check(PS.Run.order == 1, "one ordinal, got " .. tostring(PS.Run.order))
end)

case("ENCOUNTER_END still works on its own where it does fire", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(90)

	PS.Events:Handle("ENCOUNTER_END", 2900, "Grimbill", 8, 5, 1)

	check(PS.Run.killed[2900] == 90, "recorded, got " .. tostring(PS.Run.killed[2900]))
	check(partyCount(game) == 1, "and announced, got " .. partyCount(game))
end)

case("a wipe is not a kill, from either direction", function()
	local game, PS = harness.load()
	inKey(game, PS)
	game:advance(75)

	PS.Events:Handle("ENCOUNTER_END", 2900, "Grimbill", 8, 5, 0)

	-- An uncompleted boss criterion is the same statement: still alive.
	game.criteria = {
		{ criteriaType = 165, assetID = 2900, description = "Grimbill", completed = false, elapsed = 0 },
	}
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(killCount(PS.Run) == 0, "nothing recorded, got " .. killCount(PS.Run))
	check(partyCount(game) == 0, "nothing said, got " .. partyCount(game))
end)

case("a reload adopts the bosses already down, silently", function()
	local game, PS = harness.load()
	game.inGroup = true
	game.activeMapID = MURDER_ROW
	game.keystoneLevel = 10
	game.challengeActive = true
	game.worldTimers = { { elapsed = 640, type = CHALLENGE_MODE_TIMER } }

	-- Two bosses died before we loaded. The group heard about them at the time
	-- - from somebody, or from nobody - and does not need them again now.
	game.criteria = {
		harness.forcesCriterion(70),
		harness.bossCriterion(2900, "Grimbill", 328),
		harness.bossCriterion(2901, "Second", 42),
	}

	PS.Events:Handle("PLAYER_ENTERING_WORLD")

	check(PS.Run.active, "the key is picked back up")
	check(killCount(PS.Run) == 2, "both bosses adopted, got " .. killCount(PS.Run))
	check(PS.Run.killed[2900] == 312, "the first at 312s, got " .. tostring(PS.Run.killed[2900]))
	check(PS.Run.killed[2901] == 598, "the second at 598s, got " .. tostring(PS.Run.killed[2901]))
	check(partyCount(game) == 0,
		"and not one stale split posted, got " .. partyCount(game))

	-- The ordinal is the point of adopting them: the next kill is boss three.
	check(PS.Run.order == 2, "the ordinal caught up, got " .. tostring(PS.Run.order))

	game.criteria[4] = harness.bossCriterion(2902, "Third", 0)
	game.worldTimers[1].elapsed = 700
	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(PS.Run.order == 3, "and the next boss is the third, got " .. tostring(PS.Run.order))
	check(partyCount(game) == 1, "which IS announced, got " .. partyCount(game))
end)

case("nothing is read from the objective list outside a run", function()
	local game, PS = harness.load()
	game.inGroup = true
	game.criteria = { harness.bossCriterion(2900, "Grimbill", 0) }

	PS.Events:Handle("SCENARIO_CRITERIA_UPDATE")

	check(not PS.Run.active, "no run")
	check(killCount(PS.Run) == 0, "nothing recorded")
	check(partyCount(game) == 0, "nothing said")
end)

--------------------------------------------------------------------------------

io.write(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
