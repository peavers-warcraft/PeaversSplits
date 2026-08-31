--------------------------------------------------------------------------------
-- Two copies of the addon, one keystone, and whether they agree.
--
-- Everything here runs TWO real loads of PeaversSplits and passes real addon
-- messages between them, because the thing under test is agreement between
-- machines and a single client can only ever agree with itself.
--
-- The two clients are given different `GetTime()` epochs on purpose. That is
-- the assumption the protocol is built to avoid - a claim carries how far into
-- the run we are, never a timestamp - so if any of it quietly leaked a raw
-- GetTime() across the wire, the numbers here would be thousands of seconds out
-- rather than subtly wrong.
--------------------------------------------------------------------------------

local harness = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".")
	.. "/harness.lua")

local MURDER_ROW = 587
local CHALLENGE_MODE_TIMER = 1
local GRIMBILL = 2900

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

---Every party-channel line either client sent, across both of them.
local function partyLines(...)
	local lines = {}
	for _, client in ipairs({ ... }) do
		for _, sent in ipairs(client.game.sent) do
			if sent.channel == "PARTY" then
				lines[#lines + 1] = client.name .. ": " .. sent.message
			end
		end
	end
	return lines
end

local function near(a, b, tolerance)
	return a and b and math.abs(a - b) <= tolerance
end

--------------------------------------------------------------------------------

case("the two clients really do have different clocks", function()
	local wire, a, b = harness.loadPair()

	local ta, tb
	wire:as(a, function() ta = GetTime() end)
	wire:as(b, function() tb = GetTime() end)

	check(ta ~= tb, ("epochs differ (%s vs %s)"):format(tostring(ta), tostring(tb)))
	check(math.abs(ta - tb) > 1000, "and differ by more than any latency could explain")
end)

case("two clients that both saw the start agree, and only one talks", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)

	check(a.PS.Run.active and b.PS.Run.active, "both are timing the key")

	-- Each has seen the other, and neither adopts: two exact clocks already
	-- agree, so swapping between them would be churn that changes no output.
	check(b.PS.Sync.peers[a.name] ~= nil, "Bravo sees Alpha")
	check(a.PS.Sync.peers[b.name] ~= nil, "Alpha sees Bravo")
	check(a.PS.Run.clockSource == nil and b.PS.Run.clockSource == nil,
		"neither adopts the other - equal clocks are left alone")

	-- Lowest name wins the tie, and both must reach that answer independently.
	check(a.PS.Sync.speaker == a.name, "Alpha elects Alpha, got " .. tostring(a.PS.Sync.speaker))
	check(b.PS.Sync.speaker == a.name, "Bravo elects Alpha too, got " .. tostring(b.PS.Sync.speaker))
	check(a.PS.Sync:ShouldAnnounce(), "Alpha will speak")

	local bravoSpeaks
	wire:as(b, function() bravoSpeaks = b.PS.Sync:ShouldAnnounce() end)
	check(not bravoSpeaks, "Bravo will not")
end)

case("one boss, one line in party chat", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)

	-- The kill happens to both of them, because it happened in the dungeon.
	for _, client in ipairs({ a, b }) do
		wire:as(client, function()
			client.PS.Events:Handle("ENCOUNTER_END", GRIMBILL, "Grimbill", 8, 5, 1)
		end)
	end
	wire:advance(1)

	local lines = partyLines(a, b)
	check(#lines == 1, ("exactly one party line, got %d:\n        %s")
		:format(#lines, table.concat(lines, "\n        ")))
	check(lines[1] and lines[1]:find("Alpha", 1, true) ~= nil,
		"and it came from the elected speaker")

	-- The quiet client is quiet in PARTY only. Its own player still sees it.
	local sawItLocally = false
	for _, message in ipairs(b.game.printed) do
		if message:find("Grimbill", 1, true) then
			sawItLocally = true
		end
	end
	check(sawItLocally, "the quiet client still prints the split to its own frame")
end)

case("a reloaded client takes the exact clock back off a peer", function()
	local wire, a, b = harness.loadPair()

	-- Alpha saw the start and is 754s in.
	wire:start(a, MURDER_ROW, 10)
	wire:advance(754)

	-- Bravo reloaded. Its only clock is the game's world timer, which reads 15
	-- seconds SHORT here - the death-penalty skew Run.lua's header refuses to
	-- assume either way. That gap is the whole reason this feature exists.
	b.game.activeMapID = MURDER_ROW
	b.game.keystoneLevel = 10
	b.game.challengeActive = true
	b.game.worldTimers = { { elapsed = 739, type = CHALLENGE_MODE_TIMER } }

	wire:as(b, function() b.PS.Events:Handle("PLAYER_ENTERING_WORLD") end)

	check(b.PS.Run.active, "Bravo picks the key back up")
	check(b.PS.Run.recovered, "off the world timer")

	local before
	wire:as(b, function() before = b.PS.Run:GetElapsed() end)
	check(near(before, 739, 0.1), "and starts out 15s adrift, got " .. tostring(before))

	-- Now they talk.
	wire:advance(2)

	local alphaElapsed, bravoElapsed
	wire:as(a, function() alphaElapsed = a.PS.Run:GetElapsed() end)
	wire:as(b, function() bravoElapsed = b.PS.Run:GetElapsed() end)

	check(b.PS.Run.clockSource == a.name,
		"Bravo adopts Alpha's clock, got " .. tostring(b.PS.Run.clockSource))
	check(near(bravoElapsed, alphaElapsed, 0.2),
		("the two now agree: Alpha %.1f, Bravo %.1f"):format(alphaElapsed or -1, bravoElapsed or -1))
	check(not near(bravoElapsed, 739, 1.0), "and it is no longer the world timer's answer")

	-- Alpha's clock is the good one, so nothing about it moves.
	check(a.PS.Run.clockSource == nil, "Alpha adopts nothing")
	check(a.PS.Sync.clockLeader == a.name, "Alpha holds the clock")
	check(b.PS.Sync.clockLeader == a.name, "and Bravo agrees that it does")
end)

case("the recovered client stops calling itself recovered once it has a real clock", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:advance(300)

	b.game.activeMapID, b.game.keystoneLevel, b.game.challengeActive = MURDER_ROW, 10, true
	b.game.worldTimers = { { elapsed = 290, type = CHALLENGE_MODE_TIMER } }
	wire:as(b, function() b.PS.Events:Handle("PLAYER_ENTERING_WORLD") end)
	wire:advance(2)

	-- `recovered` still means something real - the kill list is still short -
	-- but the clock caveat must not be left standing once it stops being true.
	--
	-- It cannot be suppressed at the source: Pace says it at the moment of
	-- recovery, when it IS true, and the handover happens a second later. So the
	-- requirement is that the addon comes back and says the warning no longer
	-- applies, rather than that it never warned.
	check(b.PS.Run.clockSource ~= nil, "the clock came from a peer")

	local warnedAt, correctedAt
	for index, message in ipairs(b.game.printed) do
		if message:find("the clock is the game", 1, true) then
			warnedAt = index
		end
		if message:find("Clock synced from", 1, true) then
			correctedAt = index
		end
	end

	check(warnedAt ~= nil, "it warned about the fuzzy clock at recovery")
	check(correctedAt ~= nil, "and says so when a real one arrives")
	check(warnedAt and correctedAt and correctedAt > warnedAt,
		"in that order, so the last word is the true one")

	-- Never the party's problem. Four other people did not ask which machine is
	-- holding the stopwatch.
	local leaked = false
	for _, sent in ipairs(b.game.sent) do
		if sent.message:find("Clock synced", 1, true) then
			leaked = true
		end
	end
	check(not leaked, "and keeps it out of party chat")
end)

case("the best clock is not made speaker if it will not speak", function()
	local wire, a, b = harness.loadPair()

	-- Alpha would win the tie on name, but has announcements switched off.
	a.PS.Config.announceEnabled = false

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)

	check(a.PS.Sync.clockLeader == a.name, "Alpha still holds the clock")
	check(b.PS.Sync.speaker == b.name,
		"but Bravo does the talking, got " .. tostring(b.PS.Sync.speaker))

	local bravoSpeaks
	wire:as(b, function() bravoSpeaks = b.PS.Sync:ShouldAnnounce() end)
	check(bravoSpeaks, "and Bravo knows it")

	for _, client in ipairs({ a, b }) do
		wire:as(client, function()
			client.PS.Events:Handle("ENCOUNTER_END", GRIMBILL, "Grimbill", 8, 5, 1)
		end)
	end
	wire:advance(1)

	local lines = partyLines(a, b)
	check(#lines == 1, ("the group still hears the split once, got %d"):format(#lines))
end)

case("a client that turns sync off keeps its own clock and its own voice", function()
	local wire, a, b = harness.loadPair()

	b.PS.Config.syncEnabled = false

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)

	check(next(b.PS.Sync.peers) == nil, "it files nobody on its roster")

	local bravoSpeaks
	wire:as(b, function() bravoSpeaks = b.PS.Sync:ShouldAnnounce() end)
	check(bravoSpeaks, "and answers to nobody about announcing")
end)

case("a peer timing a different key is ignored", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 12)   -- same dungeon, different keystone level
	wire:advance(2)

	check(next(a.PS.Sync.peers) == nil,
		"a +12 claim is not filed against a +10 run")
	check(next(b.PS.Sync.peers) == nil, "and the reverse")
end)

case("the leader going quiet hands the job on", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)
	check(b.PS.Sync.speaker == a.name, "Alpha is speaking")

	-- Alpha disconnects: no more heartbeats reach anybody.
	a.PS.Run:Stop()
	wire:advance(60)

	check(b.PS.Sync.peers[a.name] == nil, "Bravo drops the silent peer")
	check(b.PS.Sync.speaker == b.name,
		"and takes over, got " .. tostring(b.PS.Sync.speaker))
end)

case("a run ending clears the roster on both sides", function()
	local wire, a, b = harness.loadPair()

	wire:start(a, MURDER_ROW, 10)
	wire:start(b, MURDER_ROW, 10)
	wire:advance(2)
	check(next(b.PS.Sync.peers) ~= nil, "the roster filled up")

	for _, client in ipairs({ a, b }) do
		wire:as(client, function()
			client.PS.Events:Handle("CHALLENGE_MODE_COMPLETED")
		end)
	end
	wire:advance(2)

	check(next(a.PS.Sync.peers) == nil and next(b.PS.Sync.peers) == nil,
		"and empties when the key is done")
	check(a.PS.Sync.speaker == nil and b.PS.Sync.speaker == nil, "nobody is elected")

	-- No heartbeat may outlive the run it belonged to.
	wire:advance(120)
	check(#a.game.addonSent > 0, "it did talk during the run")
	local before = #a.game.addonSent
	wire:advance(120)
	check(#a.game.addonSent == before, "and says nothing after it")
end)

--------------------------------------------------------------------------------

case("a key that is not readable yet still syncs once it is", function()
	local wire, a, b = harness.loadPair()

	-- Both clients get CHALLENGE_MODE_START before the client has published the
	-- keystone - the ordinary case Run:ResolveRun exists for. Claims sent in that
	-- window name map 0, which every peer must refuse.
	for _, client in ipairs({ a, b }) do
		client.game.challengeActive = true
		client.game.activeMapID = nil
		client.game.keystoneLevel = 0
		wire:as(client, function()
			client.PS.Events:Handle("CHALLENGE_MODE_START", MURDER_ROW)
		end)
	end
	wire:advance(0.5)

	check(next(a.PS.Sync.peers) == nil, "nobody is filed against an unreadable key")

	-- The client catches up, as it does within a frame or two.
	for _, client in ipairs({ a, b }) do
		client.game.activeMapID = MURDER_ROW
		client.game.keystoneLevel = 10
	end
	wire:advance(3)

	-- The heartbeat is fifteen seconds out, so anything that has happened by now
	-- happened because resolving the key re-announced it.
	check(a.PS.Sync.peers[b.name] ~= nil, "Alpha sees Bravo once the key resolves")
	check(b.PS.Sync.peers[a.name] ~= nil, "and Bravo sees Alpha")
	check(b.PS.Sync.speaker == a.name,
		"and they agree on a speaker, got " .. tostring(b.PS.Sync.speaker))
end)

--------------------------------------------------------------------------------

io.write(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
