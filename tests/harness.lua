--------------------------------------------------------------------------------
-- The offline harness - loads PeaversSplitsData and PeaversSplits exactly as
-- WoW does and drives real events through them.
--
-- The point is that the DATA addon's real generated file goes through the
-- CONSUMER's real code. A harness with a hand-written fixture only re-tests the
-- belief that produced the fixture, and this addon's whole failure mode is a
-- confident sentence about a pool that is actually there.
--
-- Run with the system lua (`tests/run.sh`). Two things differ from WoW's 5.1:
-- loop control variables are const in 5.4+, and `unpack` is `table.unpack`.
-- Neither may appear in addon code - it would work in game and break here,
-- which is where the checking happens.
--------------------------------------------------------------------------------

local harness = {}

--------------------------------------------------------------------------------
-- Where the two addons live
--------------------------------------------------------------------------------

---This file is `<PeaversSplits>/tests/harness.lua`, whatever the checkout is
---called and wherever a worktree puts it, so the addon root is two levels up
---from this source and the sibling data addon is beside it. Overridable because
---a worktree is not beside its siblings.
---@return string splits, string data
local function roots()
	local here = debug.getinfo(1, "S").source:sub(2)
	local testsDir = here:match("^(.*)/[^/]+$") or "."
	local splits = testsDir .. "/.."

	local data = os.getenv("PEAVERS_SPLITS_DATA")
	if not data then
		-- Beside the addon (a normal checkout), else beside the repo the worktree
		-- belongs to (`<repo>/.claude/worktrees/<name>`).
		for _, candidate in ipairs({
			splits .. "/../PeaversSplitsData",
			splits .. "/../../../../PeaversSplitsData",
		}) do
			local toc = io.open(candidate .. "/PeaversSplitsData.toc", "r")
			if toc then
				toc:close()
				data = candidate
				break
			end
		end
	end

	assert(data, "cannot find PeaversSplitsData - set PEAVERS_SPLITS_DATA")
	return splits, data
end

--------------------------------------------------------------------------------
-- The stubbed game
--------------------------------------------------------------------------------

---A frame that answers any method with a no-op and remembers nothing. The UI is
---not what these tests are about; it only has to load without erroring.
local function newFrame()
	local frame = {}
	frame.scripts = {}
	frame.events = {}

	function frame:RegisterEvent(event)
		self.events[event] = true
	end

	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end

	function frame:SetScript(name, fn)
		self.scripts[name] = fn
	end

	function frame:GetScript(name)
		return self.scripts[name]
	end

	-- The getters that are read as VALUES rather than called for effect. A
	-- permissive stub answers these with the frame itself, and `width <= 0` then
	-- compares a table to a number and throws - so they are spelled out. The
	-- width is a plausible bar width, because PaceBar divides by it.
	frame.GetWidth = function() return 300 end
	frame.GetHeight = function() return 20 end
	frame.GetLeft = function() return 0 end
	frame.GetRight = function() return 300 end
	frame.GetTop = function() return 20 end
	frame.GetBottom = function() return 0 end
	frame.GetScale = function() return 1 end
	frame.GetEffectiveScale = function() return 1 end
	frame.GetAlpha = function() return 1 end
	frame.GetValue = function() return 0 end
	frame.GetNumPoints = function() return 0 end
	frame.GetStringWidth = function() return 50 end
	frame.IsShown = function() return true end
	frame.IsVisible = function() return true end
	frame.GetObjectType = function() return "Frame" end

	-- Everything else a frame is asked to do here is chrome. Answer it with a
	-- function that returns the frame, so chained calls and getters both survive.
	return setmetatable(frame, {
		__index = function(self, key)
			local fn = function() return self end
			rawset(self, key, fn)
			return fn
		end,
	})
end

---Install the globals the two addons touch, and return the control surface the
---tests drive them through.
---@return table game
function harness.stubGame()
	local game = {
		now = 1000.0,
		printed = {},   -- the player's own chat frame
		sent = {},      -- SendChatMessage, i.e. what the party sees
		timers = {},    -- pending C_Timer.After callbacks
		keystoneLevel = 0,
		activeMapID = nil,
		challengeActive = false,
		worldTimers = {},
		inGroup = false,
		addonSent = {},  -- C_ChatInfo.SendAddonMessage, i.e. what the wire carries
		prefixes = {},   -- what the client agreed to receive
		latency = 0,     -- world latency in ms; 0 keeps split arithmetic exact
		playerName = "Solo",
		realmName = "Ravencrest",
		playerFullName = "Solo-Ravencrest",
		criteria = {},   -- C_ScenarioInfo.GetCriteriaInfo, by index
	}

	_G.UIParent = newFrame()
	_G.CreateFrame = function() return newFrame() end
	_G.GetTime = function() return game.now end
	_G.IsInGroup = function() return game.inGroup end
	_G.SendChatMessage = function(message, channel)
		game.sent[#game.sent + 1] = { message = message, channel = channel }
	end

	_G.Enum = { WorldElapsedTimerTypes = { ChallengeMode = 1, ProvingGround = 2 } }

	-- WoW's table-clearing global. Not optional: Sync wipes its roster on every
	-- run start, before any of its "is anybody there" guards can bail out.
	_G.wipe = function(t)
		for key in pairs(t) do
			t[key] = nil
		end
		return t
	end

	_G.UnitFullName = function() return game.playerName, game.realmName end
	_G.GetNormalizedRealmName = function() return game.realmName end
	_G.UnitIsUnit = function(unit) return unit == game.playerFullName end
	-- bandwidthIn, bandwidthOut, latencyHome, latencyWorld(ms)
	_G.GetNetStats = function() return 0, 0, game.latency, game.latency end

	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix)
			game.prefixes[prefix] = true
			return true
		end,
		SendAddonMessage = function(prefix, text, channel)
			game.addonSent[#game.addonSent + 1] =
				{ prefix = prefix, text = text, channel = channel }
			return true
		end,
	}

	-- The keystone's objective list, which is where boss kills actually come
	-- from. Answers nil past the end exactly as the real one does, so a consumer
	-- that scans a fixed range has to cope with the same thing it copes with in
	-- game rather than with a tidier version of it.
	_G.C_ScenarioInfo = {
		GetCriteriaInfo = function(index)
			return game.criteria[index]
		end,
	}

	_G.C_Timer = {
		After = function(delay, fn)
			game.timers[#game.timers + 1] = { at = game.now + delay, fn = fn }
		end,
	}

	_G.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			return field == "Version" and "0.1.1" or nil
		end,
	}

	_G.C_ChallengeMode = {
		---The real one answers 0 - not nil - before the client has the run's
		---keystone. That zero is the entire bug this harness exists to hold shut.
		GetActiveKeystoneInfo = function()
			return game.keystoneLevel, {}, true
		end,
		GetActiveChallengeMapID = function() return game.activeMapID end,
		IsChallengeModeActive = function() return game.challengeActive end,
		GetMapUIInfo = function() return "Stub", nil, 1800 end,
	}

	---The real one returns the timer IDS as multiple return values - not a table,
	---and not the timers themselves. This stub used to unpack the timer objects,
	---which is a different shape from the game's in two ways at once, and it let a
	---consumer that treated the result as a table pass here while returning nil in
	---every real dungeon. The stub is the contract; it has to be the game's.
	_G.GetWorldElapsedTimers = function()
		local ids = {}
		for index = 1, #game.worldTimers do
			ids[index] = index
		end
		return table.unpack(ids)
	end

	_G.GetWorldElapsedTime = function(timerID)
		local timer = game.worldTimers[timerID]
		return timerID, timer and timer.elapsed or 0, timer and timer.type or 0
	end

	---Run every timer due at or before `now`, newest scheduling last. Draining is
	---explicit so a test says exactly how much game time it is letting pass.
	---@param seconds number
	---Time moves TO each timer rather than jumping past them: a retry that
	---reschedules itself does so against the clock as it was when it ran, so a
	---single leap to the end would leave every follow-up timer in the future and
	---silently run only the first. That is how this harness first "proved" the
	---give-up path was never reached.
	function game:advance(seconds)
		local target = self.now + seconds
		local guard = 0

		while true do
			guard = guard + 1
			assert(guard < 10000, "timer queue never drained")

			local due, index
			for i, timer in ipairs(self.timers) do
				if timer.at <= target and (not due or timer.at < due.at) then
					due, index = timer, i
				end
			end

			if not due then
				break
			end

			table.remove(self.timers, index)
			self.now = math.max(self.now, due.at)
			due.fn()
		end

		self.now = target
	end

	return game
end

--------------------------------------------------------------------------------
-- PeaversCommons, reduced to what these two addons actually call
--------------------------------------------------------------------------------

---@param game table
function harness.stubCommons(game)
	local commons = {}

	commons.Utils = {
		Debug = function() end,
		Print = function(_, message)
			game.printed[#game.printed + 1] = message
		end,
	}

	commons.ConfigManager = {
		---The real one hangs an AceDB profile off the addon. The defaults are what
		---the addon reads, so the table is enough.
		NewWithAceDB = function(_, _, defaults)
			local config = { Initialize = function() end, Save = function() end }
			for key, value in pairs(defaults) do
				config[key] = value
			end
			return config
		end,
	}

	commons.Events = {
		---Captures the bootstrap so a test can run it deliberately.
		Init = function(_, _, callback)
			commons._ready = callback
		end,
		RegisterEvent = function() end,
	}

	commons.SlashCommands = { Register = function() end }
	commons.ConfigRegistry = { Register = function() end }
	commons.SettingsUI = { CreateRedirectPage = function() end }

	_G.PeaversCommons = commons
	return commons
end

--------------------------------------------------------------------------------
-- Loading an addon the way the game does
--------------------------------------------------------------------------------

---The `.lua` files a TOC lists, in order. This is the list that decides what is
---actually loaded - a file on disk and not in here has never run in anyone's
---game, however many green commits it has.
---@param tocPath string
---@return string[] files
function harness.tocFiles(tocPath)
	local toc = assert(io.open(tocPath, "r"), "no TOC at " .. tocPath)
	local files = {}

	for raw in toc:lines() do
		local line = raw:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and not line:match("^#") and line:lower():match("%.lua$") then
			files[#files + 1] = line:gsub("\\", "/")
		end
	end

	toc:close()
	return files
end

---Load one addon: every file its TOC lists, in order, each called with
---`(addonName, addonTable)` - one shared table per addon, exactly as WoW does.
---@param root string
---@param name string
---@return table addonTable
function harness.loadAddon(root, name)
	local addonTable = {}

	for _, relative in ipairs(harness.tocFiles(root .. "/" .. name .. ".toc")) do
		local path = root .. "/" .. relative
		local chunk, err = loadfile(path)
		assert(chunk, ("%s: %s"):format(relative, tostring(err)))
		chunk(name, addonTable)
	end

    return addonTable
end

---Load the data addon then the consumer, with the game stubbed, and run the
---consumer's bootstrap. Returns the control surface and the addon's namespace.
---@return table game, table PS
function harness.load()
	local splitsRoot, dataRoot = roots()

	local game = harness.stubGame()
	local commons = harness.stubCommons(game)

	harness.loadAddon(dataRoot, "PeaversSplitsData")
	local PS = harness.loadAddon(splitsRoot, "PeaversSplits")

	assert(commons._ready, "PeaversSplits never registered a bootstrap")
	commons._ready()

	return game, PS
end

--------------------------------------------------------------------------------
-- Two clients on one wire
--
-- Sync's whole job is agreement between machines, and a single-client test can
-- only ever check that this addon agrees with itself. That is the exact trap
-- this file has already been caught by twice: the harness supplied the answer
-- and then confirmed it. So the sync tests run TWO real loads of the addon and
-- pass real addon messages between them.
--
-- The one thing that must not be shared is the clock epoch. `GetTime()` counts
-- from when each client started, so the two are deliberately given different
-- epochs over one shared wall clock - if any of the protocol quietly assumed a
-- common zero, these tests would be the thing that noticed.
--------------------------------------------------------------------------------

---Load one addon instance against a freshly stubbed game.
---@param name string `Name-Realm`
---@param epoch number seconds this client had been running at wall time zero
---@return table client
local function loadClient(name, epoch)
	local splitsRoot, dataRoot = roots()

	local game = harness.stubGame()
	local commons = harness.stubCommons(game)

	local short, realm = name:match("^([^%-]+)%-(.+)$")
	game.playerName, game.realmName, game.playerFullName = short, realm, name
	game.inGroup = true

	harness.loadAddon(dataRoot, "PeaversSplitsData")
	local PS = harness.loadAddon(splitsRoot, "PeaversSplits")

	assert(commons._ready, "PeaversSplits never registered a bootstrap")
	commons._ready()

	return {
		name = name,
		shortName = short,
		realm = realm,
		epoch = epoch,
		game = game,
		commons = commons,
		PS = PS,
	}
end

---A completed "defeat this boss" objective, `ago` seconds after the fact.
---@param encounterID number DungeonEncounterID
---@param name string
---@param ago number|nil seconds since the boss died, as the game reports it
---@return table criteriaInfo
function harness.bossCriterion(encounterID, name, ago)
	return {
		criteriaType = 165,   -- Enum.CriteriaType.DefeatDungeonEncounter
		assetID = encounterID,
		description = name,
		completed = true,
		elapsed = ago or 0,
	}
end

---An objective that is NOT a boss - the enemy-forces bar, which is what most
---SCENARIO_CRITERIA_UPDATE events are actually about.
---@return table criteriaInfo
function harness.forcesCriterion(percent)
	return {
		criteriaType = 46,
		assetID = 0,
		description = "Enemy Forces",
		isWeightedProgress = true,
		quantityString = tostring(percent) .. "%",
		completed = percent >= 100,
		elapsed = 0,
	}
end

---Load two clients and wire them together.
---
---Both are loaded first, THEN the routing globals are installed - because Lua
---resolves globals at call time, so whichever stub was installed last would
---otherwise serve both clients and the test would be timing one machine twice.
---@return table wire, table a, table b
function harness.loadPair()
	local bus = { wall = 1000.0, outbox = {} }

	-- Different epochs, neither of them zero. A protocol that leaked a raw
	-- GetTime() across the wire would be off by 4863 seconds here.
	local a = loadClient("Alpha-Ravencrest", 5000)
	local b = loadClient("Bravo-Ravencrest", 137)
	local clients = { a, b }

	local activeClient = a

	local function syncClocks()
		for _, client in ipairs(clients) do
			client.game.now = bus.wall + client.epoch
		end
	end
	syncClocks()

	_G.GetTime = function() return activeClient.game.now end
	_G.IsInGroup = function() return activeClient.game.inGroup end
	_G.UnitFullName = function() return activeClient.shortName, activeClient.realm end
	_G.GetNormalizedRealmName = function() return activeClient.realm end
	_G.UnitIsUnit = function(unit) return unit == activeClient.name end
	_G.GetNetStats = function()
		local latency = activeClient.game.latency
		return 0, 0, latency, latency
	end

	_G.SendChatMessage = function(message, channel)
		local sent = activeClient.game.sent
		sent[#sent + 1] = { message = message, channel = channel }
	end

	_G.C_Timer = {
		After = function(delay, fn)
			local timers = activeClient.game.timers
			timers[#timers + 1] = { at = activeClient.game.now + delay, fn = fn }
		end,
	}

	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix)
			activeClient.game.prefixes[prefix] = true
			return true
		end,
		SendAddonMessage = function(prefix, text, channel)
			local game = activeClient.game
			game.addonSent[#game.addonSent + 1] =
				{ prefix = prefix, text = text, channel = channel }
			-- PARTY loops back to its own sender in the real client, so it goes on
			-- the bus for everyone including us. Filtering self is the addon's job
			-- and must be exercised, not quietly done here.
			bus.outbox[#bus.outbox + 1] =
				{ prefix = prefix, text = text, channel = channel, sender = activeClient.name }
			return true
		end,
	}

	_G.C_ScenarioInfo = {
		GetCriteriaInfo = function(index) return activeClient.game.criteria[index] end,
	}

	_G.C_ChallengeMode = {
		GetActiveKeystoneInfo = function() return activeClient.game.keystoneLevel, {}, true end,
		GetActiveChallengeMapID = function() return activeClient.game.activeMapID end,
		IsChallengeModeActive = function() return activeClient.game.challengeActive end,
		GetMapUIInfo = function() return "Stub", nil, 1800 end,
	}

	_G.GetWorldElapsedTimers = function()
		local ids = {}
		for index = 1, #activeClient.game.worldTimers do
			ids[index] = index
		end
		return table.unpack(ids)
	end

	_G.GetWorldElapsedTime = function(timerID)
		local timer = activeClient.game.worldTimers[timerID]
		return timerID, timer and timer.elapsed or 0, timer and timer.type or 0
	end

	local wire = { bus = bus, clients = clients }

	---Run `fn` as though we were sitting at `client`'s keyboard.
	function wire:as(client, fn)
		local previous = activeClient
		activeClient = client
		local ok, err = pcall(fn)
		activeClient = previous
		if not ok then
			error(err, 0)
		end
	end

	---Hand every queued addon message to every client, sender included.
	function wire:deliver()
		local guard = 0
		while #bus.outbox > 0 do
			guard = guard + 1
			assert(guard < 1000, "addon messages never stopped bouncing")

			local message = table.remove(bus.outbox, 1)
			for _, client in ipairs(clients) do
				self:as(client, function()
					client.PS.Events:Handle("CHAT_MSG_ADDON",
						message.prefix, message.text, message.channel, message.sender)
				end)
			end
		end
	end

	---Move the shared wall clock forward, running each client's timers as they
	---come due and delivering whatever they say. Time moves TO each timer for the
	---same reason `game:advance` does it: a retry that reschedules itself has to
	---see the clock as it was when it ran.
	---@param seconds number
	function wire:advance(seconds)
		local target = bus.wall + seconds
		local guard = 0

		self:deliver()

		while true do
			guard = guard + 1
			assert(guard < 10000, "timer queue never drained")

			local dueClient, dueIndex, dueAt
			for _, client in ipairs(clients) do
				for index, timer in ipairs(client.game.timers) do
					local wallAt = timer.at - client.epoch
					if wallAt <= target and (not dueAt or wallAt < dueAt) then
						dueClient, dueIndex, dueAt = client, index, wallAt
					end
				end
			end

			if not dueClient then
				break
			end

			local timer = table.remove(dueClient.game.timers, dueIndex)
			bus.wall = math.max(bus.wall, dueAt)
			syncClocks()
			self:as(dueClient, timer.fn)
			self:deliver()
		end

		bus.wall = target
		syncClocks()
		self:deliver()
	end

	---Put a client into a key that started `elapsed` seconds ago, as the client
	---itself would see it at CHALLENGE_MODE_START.
	function wire:start(client, mapID, level)
		client.game.activeMapID = mapID
		client.game.keystoneLevel = level
		client.game.challengeActive = true
		self:as(client, function()
			client.PS.Events:Handle("CHALLENGE_MODE_START", mapID)
		end)
		self:deliver()
	end

	return wire, a, b
end

return harness
