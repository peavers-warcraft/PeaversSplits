--------------------------------------------------------------------------------
-- Adopting a keystone that was already running when the addon loaded, which is
-- what a `/reload` inside a dungeon does.
--
-- The bug these exist for: `/reload` mid-key left the bar hidden and `/ps`
-- answering "no keystone running" for the rest of the run.
--
-- Two independent causes, and the tests are split the same way:
--
--   1. `GetWorldElapsedTimers` returns the timer ids as MULTIPLE RETURN VALUES.
--      `Run` read the first of them into one local and required it to be a
--      table, so the recovery clock was nil in every real dungeon. The harness
--      hid this by unpacking timer OBJECTS - a shape the game never produces -
--      so the stub agreed with the consumer and both were wrong together.
--
--   2. `PLAYER_ENTERING_WORLD` fires when the loading screen ends; the server
--      pushes the challenge-mode state and the world timer afterwards. Recovery
--      was a single attempt at that one moment, so even a correct clock was a
--      race the addon usually lost.
--
-- The rule being held: a key that is running must be picked back up, whether
-- the facts are there at world entry or arrive a second later.
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

---Put the game into the state a `/reload` lands in: standing in a key that has
---been going for `elapsed` seconds, with everything the server has already sent.
local function midKey(game, elapsed)
	game.challengeActive = true
	game.activeMapID = MURDER_ROW
	game.keystoneLevel = 10
	game.worldTimers = { { elapsed = elapsed, type = CHALLENGE_MODE_TIMER } }
end

--------------------------------------------------------------------------------

case("the harness answers GetWorldElapsedTimers the way the game does", function()
	local game = harness.stubGame()
	game.worldTimers = {
		{ elapsed = 61, type = 2 },
		{ elapsed = 754, type = CHALLENGE_MODE_TIMER },
	}

	-- Multiple return values, not a table. This is the contract the consumer
	-- got wrong, so it is asserted here directly rather than only through it.
	local first, second, third = GetWorldElapsedTimers()
	check(type(first) == "number" and type(second) == "number" and third == nil,
		"returns one id per timer as separate values, got "
			.. type(first) .. "/" .. type(second) .. "/" .. type(third))

	local _, elapsed, timerType = GetWorldElapsedTime(second)
	check(elapsed == 754 and timerType == CHALLENGE_MODE_TIMER,
		"an id looks its own timer up, got " .. tostring(elapsed))
end)

case("a /reload mid-key, with everything ready at world entry", function()
	local game, PS = harness.load()
	midKey(game, 754)

	PS.Events:Handle("PLAYER_ENTERING_WORLD")

	check(PS.Run.active, "the key is picked back up")
	check(PS.Run.recovered, "and is marked recovered, so Pace can say so")
	check(PS.Run.mapID == MURDER_ROW, "the dungeon is read from the API, got "
		.. tostring(PS.Run.mapID))
	check(PS.Run.level == 10, "the keystone level is read, got " .. tostring(PS.Run.level))

	-- The whole point of recovering: there is a clock again. Without it a split
	-- cannot be taken and every boss for the rest of the key is silent.
	local elapsed = PS.Run:GetElapsed()
	check(elapsed == 754, "the clock comes from the game's timer, got " .. tostring(elapsed))
	check(PS.Run.startedAt == nil, "and is NOT faked into a precise start instant")
end)

case("a /reload mid-key, with the server state arriving after the loading screen", function()
	local game, PS = harness.load()

	-- World entry with nothing published yet - the ordinary case, because the
	-- server sends this after the loading screen ends.
	PS.Events:Handle("PLAYER_ENTERING_WORLD")
	check(not PS.Run.active, "nothing is adopted while the game says nothing")

	midKey(game, 812)
	game:advance(3)

	check(PS.Run.active, "the retry picks the key up once the state lands")
	check(PS.Run.level == 10, "with the level, got " .. tostring(PS.Run.level))
	check(PS.Run:GetElapsed() == 812, "and the clock, got " .. tostring(PS.Run:GetElapsed()))
end)

case("WORLD_STATE_TIMER_START adopts the key on its own", function()
	local game, PS = harness.load()
	midKey(game, 400)

	-- The event that says the keystone clock has arrived. An addon listening
	-- only to PLAYER_ENTERING_WORLD has already had its one look by now.
	PS.Events:Handle("WORLD_STATE_TIMER_START")

	check(PS.Run.active, "the key is adopted")
	check(PS.Run:GetElapsed() == 400, "with the clock, got " .. tostring(PS.Run:GetElapsed()))
end)

case("two events racing to recover adopt one run", function()
	local game, PS = harness.load()
	midKey(game, 500)

	PS.Events:Handle("PLAYER_ENTERING_WORLD")
	PS.Events:Handle("WORLD_STATE_TIMER_START")
	game:advance(3)

	check(PS.Run.active, "the key is running")
	-- Recover() wipes the kill list, so adopting twice would silently discard
	-- splits taken between the two events.
	check(PS.Run.recovered, "still marked recovered")

	local kills = 0
	for _ in pairs(PS.Run.killed) do kills = kills + 1 end
	check(kills == 0, "one adoption, not two")
end)

case("a recovered key still takes splits", function()
	local game, PS = harness.load()
	midKey(game, 600)
	PS.Events:Handle("PLAYER_ENTERING_WORLD")

	game.worldTimers[1].elapsed = 655
	PS.Events:Handle("ENCOUNTER_END", 2900, "Grimbill", 8, 5, 1)

	check(PS.Run.killed[2900] == 655,
		"the boss is split against the game's clock, got " .. tostring(PS.Run.killed[2900]))
end)

case("world entry with no keystone leaves the addon alone", function()
	local game, PS = harness.load()

	PS.Events:Handle("PLAYER_ENTERING_WORLD")
	game:advance(30)

	check(not PS.Run.active, "nothing is adopted outside a key")
	check(#game.timers == 0, "and the retry gives up rather than running forever")
end)

case("a key that ends is let go of, and not re-adopted", function()
	local game, PS = harness.load()
	midKey(game, 900)
	PS.Events:Handle("PLAYER_ENTERING_WORLD")
	check(PS.Run.active, "the key is running")

	-- Walking out: the dungeon is behind us and the game says so.
	game.challengeActive = false
	game.worldTimers = {}
	PS.Events:Handle("PLAYER_ENTERING_WORLD")
	game:advance(30)

	check(not PS.Run.active, "the run is dropped on leaving")
end)

--------------------------------------------------------------------------------

io.write(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
