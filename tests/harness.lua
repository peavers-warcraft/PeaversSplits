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
	}

	_G.UIParent = newFrame()
	_G.CreateFrame = function() return newFrame() end
	_G.GetTime = function() return game.now end
	_G.IsInGroup = function() return game.inGroup end
	_G.SendChatMessage = function(message, channel)
		game.sent[#game.sent + 1] = { message = message, channel = channel }
	end

	_G.Enum = { WorldElapsedTimerTypes = { ChallengeMode = 1, ProvingGround = 2 } }

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

	_G.GetWorldElapsedTimers = function() return table.unpack(game.worldTimers) end
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

return harness
