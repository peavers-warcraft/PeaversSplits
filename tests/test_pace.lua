--------------------------------------------------------------------------------
-- What the addon says at the start of a key, held against the real published
-- data in PeaversSplitsData.
--
-- The bug these exist for: a +10 Murder Row - 54 published runs at every boss -
-- was announced as "No pace published for Murder Row +10 yet" at the moment the
-- key started, because `C_ChallengeMode.GetActiveKeystoneInfo()` answers 0
-- before the client has the run's keystone, and 0 is true in Lua. Nothing
-- crashed and nothing looked wrong; the addon simply said something confident
-- and false about a dungeon it had complete data for.
--
-- So the guard is not "does the lookup work" - it always did. It is: the addon
-- must never turn a level it could not read into a claim about the pool.
--------------------------------------------------------------------------------

local harness = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".")
	.. "/harness.lua")

local MURDER_ROW = 587

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

---Did anything the player was shown contain this text?
local function said(game, needle)
	for _, message in ipairs(game.printed) do
		if message:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function transcript(game)
	return "        seen: " .. (#game.printed == 0 and "(nothing)"
		or table.concat(game.printed, " | "))
end

local function case(name, fn)
	io.write(name .. "\n")
	fn()
end

--------------------------------------------------------------------------------

case("the published data really does cover Murder Row +10", function()
	local _, _ = harness.load()
	local api = _G.PeaversSplitsData.API

	check(api.GetDungeonName(MURDER_ROW) == "Murder Row", "587 is Murder Row")

	local bosses = api.GetBosses(MURDER_ROW, 10)
	check(bosses ~= nil, "GetBosses(587, 10) returns a pool")

	local count = 0
	for _ in pairs(bosses or {}) do count = count + 1 end
	check(count == 4, "the +10 pool has all four bosses, got " .. count)
end)

case("a +10 announced before the client has the keystone", function()
	local game, PS = harness.load()

	-- Exactly the real sequence: the event arrives, and the level is not there
	-- yet. This is the case that shipped the wrong sentence.
	game.keystoneLevel = 0
	game.activeMapID = MURDER_ROW
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)

	check(not said(game, "No pace published"),
		"does not claim the key is uncovered\n" .. transcript(game))
	check(not said(game, "+0"),
		"does not invent a +0 keystone\n" .. transcript(game))

	-- The clock must start regardless - it is the one thing that cannot wait.
	check(PS.Run.active, "the run is being tracked")
	check(PS.Run.startedAt ~= nil, "the clock started at the event, not at the level")

	-- Now the client catches up, as it does within a frame or two.
	game.keystoneLevel = 10
	game:advance(0.5)

	check(PS.Run.level == 10, "the level resolves to 10, got " .. tostring(PS.Run.level))
	check(said(game, "Pacing Murder Row +10"),
		"announces the real pool once the level is readable\n" .. transcript(game))
end)

case("a +10 announced when the keystone is already readable", function()
	local game, PS = harness.load()

	game.keystoneLevel = 10
	game.activeMapID = MURDER_ROW
	game.challengeActive = true

	-- The bootstrap schedules a timer of its own, so count the delta rather than
	-- the queue.
	local before = #game.timers
	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)

	check(said(game, "Pacing Murder Row +10"),
		"announces immediately, with no timer needed\n" .. transcript(game))
	check(#game.timers == before, "schedules no retry it does not need")
end)

case("a level that genuinely has no pool still says so", function()
	local game, PS = harness.load()

	-- Murder Row publishes 7, 9, 10, 11, 12. A +14 is a real miss, and the honest
	-- answer is still to name what exists rather than reach for a nearby level.
	game.keystoneLevel = 14
	game.activeMapID = MURDER_ROW
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)

	check(said(game, "No pace published for Murder Row +14 yet"),
		"reports the uncovered level\n" .. transcript(game))
	check(said(game, "7, 9, 10, 11, 12"),
		"lists the levels that do have data\n" .. transcript(game))
	check(not said(game, "Pacing"), "compares against nothing")
end)

case("a keystone level that never arrives", function()
	local game, PS = harness.load()

	game.keystoneLevel = 0
	game.activeMapID = MURDER_ROW
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)
	game:advance(30)

	check(said(game, "Could not read the keystone level"),
		"blames the reading, not the pool\n" .. transcript(game))
	check(not said(game, "No pace published"),
		"never dresses an unread level as an unpublished one\n" .. transcript(game))
end)

case("a key reset while the level is still resolving", function()
	local game, PS = harness.load()

	game.keystoneLevel = 0
	game.activeMapID = MURDER_ROW
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)
	PS.Events:Handle("CHALLENGE_MODE_RESET", MURDER_ROW)

	-- The group re-keys and the level is readable this time.
	game.keystoneLevel = 10
	game:advance(30)

	check(not PS.Run.active, "the abandoned run stays stopped")
	check(not said(game, "Pacing"),
		"the orphaned retry announces nothing\n" .. transcript(game))
end)

--------------------------------------------------------------------------------
-- The dungeon, which is the other half of "which key is this".
--
-- Reported from a live +10 Voidscar Arena: "No published pace for this dungeon
-- yet", over a dungeon with 21 published runs at exactly that level. The map id
-- was being taken from the `CHALLENGE_MODE_START` payload, which is not the
-- `mapChallengeModeID` the pool is keyed by.
--
-- **These tests exist because the ones above could not have caught it.** Every
-- case here fires the event with the map id in hand AND sets `activeMapID` to
-- the same value, so the payload and the API agreed and the addon's choice
-- between them never mattered. The harness supplied the answer the code was
-- supposed to look up. So these cases make them DISAGREE, which is the only way
-- the question gets asked at all.
--------------------------------------------------------------------------------

local VOIDSCAR = 585

case("the dungeon comes from the API, not from the event payload", function()
	local game, PS = harness.load()

	game.keystoneLevel = 10
	game.activeMapID = VOIDSCAR
	game.challengeActive = true

	-- The payload carries something that is not a mapChallengeModeID. Whether the
	-- real client sends nil or an id from another space, the addon must not be
	-- reading it: 2664 is not in the pool at all.
	PS.Events:Handle("CHALLENGE_MODE_START", 2664)

	check(PS.Run.mapID == VOIDSCAR,
		"the run is on 585, got " .. tostring(PS.Run.mapID))
	check(said(game, "Pacing Voidscar Arena +10"),
		"paces the real dungeon\n" .. transcript(game))
	check(not said(game, "No published pace"),
		"does not report a covered dungeon as uncovered\n" .. transcript(game))
end)

case("a payload of nil is not the dungeon either", function()
	local game, PS = harness.load()

	game.keystoneLevel = 10
	game.activeMapID = VOIDSCAR
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START")

	check(said(game, "Pacing Voidscar Arena +10"),
		"an absent payload costs nothing\n" .. transcript(game))
	check(not said(game, "map nil"),
		"never prints a map id it failed to read\n" .. transcript(game))
end)

case("a dungeon the client has not published yet waits, like the level does", function()
	local game, PS = harness.load()

	-- Both halves unreadable at the instant the event lands, which is the state
	-- the level retry was built for. The map id now gets the same treatment.
	game.keystoneLevel = 0
	game.activeMapID = nil
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", 2664)

	check(not said(game, "No published pace"),
		"says nothing about a pool it could not look up\n" .. transcript(game))
	check(PS.Run.active, "the clock still started")

	game.activeMapID = VOIDSCAR
	game.keystoneLevel = 10
	game:advance(0.5)

	check(said(game, "Pacing Voidscar Arena +10"),
		"announces once the client catches up\n" .. transcript(game))
end)

case("a dungeon that never becomes readable says so, and says which half", function()
	local game, PS = harness.load()

	game.keystoneLevel = 10
	game.activeMapID = nil
	game.challengeActive = true

	PS.Events:Handle("CHALLENGE_MODE_START", 2664)
	game:advance(30)

	check(said(game, "Could not read which dungeon this is"),
		"names the fact that was missing\n" .. transcript(game))
	check(not said(game, "No published pace"),
		"does not blame the pool for a read it could not make\n" .. transcript(game))
end)

--------------------------------------------------------------------------------
-- The test bar. It exists so the layout can be judged outside a key, so what
-- matters is that it goes through the SAME Refresh a real run does - a preview
-- with its own drawing code would agree with the real bar only until one of
-- them changed.
--------------------------------------------------------------------------------

case("the test bar draws without a key", function()
	local _, PS = harness.load()

	check(not PS.PaceBar:IsPreviewing(), "starts off")
	check(PS.PaceBar:GetState().shown == false, "and the bar starts hidden")

	check(PS.PaceBar:TogglePreview() == true, "toggling turns it on")

	local state = PS.PaceBar:GetState()
	check(state.shown == true, "the bar is drawn with no run active")
	check(state.preview == true, "and knows it is showing invented numbers")
	check(state.header ~= nil and state.header:find("Preview:", 1, true) ~= nil,
		"its header says so, got " .. tostring(state.header))

	-- The geometry is the whole point: a track with no band or tick would look
	-- fine in a screenshot and tell you nothing about placement.
	check((state.bandWidth or 0) > 0, "the band has width, got " .. tostring(state.bandWidth))
	check((state.tick or 0) > 0, "the tick is placed, got " .. tostring(state.tick))
	check((state.fillWidth or 0) > 0, "the fill has width, got " .. tostring(state.fillWidth))

	-- It opens on the pace, so the first thing drawn is the state that shows the
	-- most: fill, band and tick together rather than an empty track.
	check(math.abs((state.fillWidth or 0) - (state.tick or 0)) < 2,
		("the fill opens on the tick, %s vs %s")
			:format(tostring(state.fillWidth), tostring(state.tick)))
	check(state.delta == "on pace", "and reads as on pace, got " .. tostring(state.delta))

	check(PS.PaceBar:TogglePreview() == false, "toggling again turns it off")
	check(PS.PaceBar:GetState().shown == false, "and hides the bar")
end)

case("the test bar ignores the show-bar checkbox", function()
	local _, PS = harness.load()

	-- Someone with the bar switched off is exactly the person who wants to see
	-- what they would be switching on.
	PS.Config.showBar = false
	PS.PaceBar:SetPreview(true)

	check(PS.PaceBar:GetState().shown == true, "still draws when the bar is disabled")
end)

case("the test bar sweeps, so both colours can be seen", function()
	local game, PS = harness.load()

	PS.PaceBar:SetPreview(true)
	local first = PS.PaceBar:GetState().fillWidth

	-- Far enough round the loop to be unmistakably elsewhere, but not a whole
	-- cycle back to the start.
	game.now = game.now + 5
	PS.PaceBar:Refresh()
	local second = PS.PaceBar:GetState().fillWidth

	check(second ~= first,
		("the fill moves with the clock, %s then %s"):format(tostring(first), tostring(second)))
end)

case("a real key takes the bar back from the test bar", function()
	local game, PS = harness.load()

	PS.PaceBar:SetPreview(true)
	check(PS.PaceBar:IsPreviewing(), "previewing before the key")

	game.keystoneLevel = 10
	game.activeMapID = MURDER_ROW
	game.challengeActive = true
	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)

	check(not PS.PaceBar:IsPreviewing(), "the key reclaims the bar")

	local state = PS.PaceBar:GetState()
	check(state.preview == false, "and the bar stops calling itself a preview")
	check(state.header ~= nil and state.header:find("Next:", 1, true) ~= nil,
		"it is racing a real boss, got " .. tostring(state.header))
end)

case("the test bar refuses to start mid-key", function()
	local game, PS = harness.load()

	game.keystoneLevel = 10
	game.activeMapID = MURDER_ROW
	game.challengeActive = true
	PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)

	PS.PaceBar:SetPreview(true)

	check(not PS.PaceBar:IsPreviewing(),
		"a running key is not overwritten with a sample\n" .. transcript(game))
	check(said(game, "not while a key is running"), "and says why\n" .. transcript(game))
end)

--------------------------------------------------------------------------------
-- Every .lua on disk is listed in the TOC, and every listed file exists.
-- A file in one and not the other is the failure that froze PeaversConsumables
-- for a month: still committed, still packaged, never loaded.
--------------------------------------------------------------------------------

case("the TOCs and the files on disk agree", function()
	local function checkToc(root, name)
		local listed = {}
		for _, relative in ipairs(harness.tocFiles(root .. "/" .. name .. ".toc")) do
			listed[relative] = true
			local file = io.open(root .. "/" .. relative, "r")
			check(file ~= nil, ("%s lists %s and it exists"):format(name, relative))
			if file then file:close() end
		end

		-- `tests/` is deliberately not shipped, so it is not expected in the TOC.
		local find = io.popen(("find %q -name '*.lua' -not -path '*/tests/*' -not -path '*/.git/*'")
			:format(root))
		for raw in find:lines() do
			local line = raw
			local relative = line:sub(#root + 2)
			check(listed[relative] == true,
				("%s: %s is on disk and in the TOC"):format(name, relative))
		end
		find:close()
	end

	local splitsRoot = (debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/.."
	checkToc(splitsRoot, "PeaversSplits")
end)

--------------------------------------------------------------------------------

io.write(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
